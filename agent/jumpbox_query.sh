#!/usr/bin/env bash
# Run an AI Search agent query from a jump box INSIDE the VNet.
#
# Self-contained: bootstraps a Python venv, installs the agent SDK, resolves the
# project's AI Search connection, creates a temporary agent, asks one question,
# prints the grounded answer (with its citation), and deletes the agent.
# Auth uses the VM's managed identity (DefaultAzureCredential) - no `az login`.
#
# Usage from your workstation (no SSH needed) - pass config as params. Because
# `az vm run-command` cannot pass values containing spaces, send your question
# base64-encoded as QUESTION_B64 (the script decodes it):
#
#   $q = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("How long does express shipping take?"))
#   az vm run-command invoke -g <rg> -n <jumpbox-vm> --command-id RunShellScript `
#     --scripts "@agent/jumpbox_query.sh" --parameters `
#       "PROJECT_ENDPOINT=https://<acct>.services.ai.azure.com/api/projects/<proj>" `
#       "AI_SEARCH_CONNECTION_NAME=<search-connection-name>" `
#       "QUESTION_B64=$q"
#
# Without QUESTION_B64 the default question below is used.
# Get the config values from `terraform output` in the terraform/ folder.
set -euo pipefail

# --- Config (override via environment / run-command --parameters) -------------
export PROJECT_ENDPOINT="${PROJECT_ENDPOINT:-}"                       # project_endpoint output
export MODEL_DEPLOYMENT_NAME="${MODEL_DEPLOYMENT_NAME:-gpt-4o}"       # model_deployment_name output
export AI_SEARCH_CONNECTION_NAME="${AI_SEARCH_CONNECTION_NAME:-}"     # ai_search_connection_name output
export AI_SEARCH_INDEX_NAME="${AI_SEARCH_INDEX_NAME:-agent-sample-index}"
export QUESTION="${QUESTION:-What is your warranty, and what does it not cover?}"
# Multi-word questions: pass base64 via QUESTION_B64 (avoids run-command space limits).
if [[ -n "${QUESTION_B64:-}" ]]; then
  export QUESTION="$(echo "$QUESTION_B64" | base64 -d)"
fi

if [[ -z "$PROJECT_ENDPOINT" || -z "$AI_SEARCH_CONNECTION_NAME" ]]; then
  echo "ERROR: set PROJECT_ENDPOINT and AI_SEARCH_CONNECTION_NAME (see header)." >&2
  exit 1
fi

echo "===== 1. PRIVATE DNS RESOLUTION (expect 192.168.x private IPs) ====="
foundry_host="$(echo "$PROJECT_ENDPOINT" | sed -E 's#https://([^.]+)\..*#\1#')"
for host in "${AI_SEARCH_CONNECTION_NAME}.search.windows.net" "${foundry_host}.services.ai.azure.com" ; do
  printf '   %-45s -> %s\n' "$host" "$(getent hosts "$host" | awk '{print $1}' | paste -sd, - || echo '(none)')"
done

echo
echo "===== 2. BOOTSTRAP PYTHON ENV ====="
if [[ ! -x /opt/venv/bin/python ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1
  apt-get install -y python3-venv python3-pip >/dev/null 2>&1
  python3 -m venv /opt/venv
  /opt/venv/bin/pip install --quiet --upgrade pip
fi
/opt/venv/bin/pip install --quiet \
  "azure-identity>=1.17.0" \
  "azure-ai-projects>=2.0.0"

echo
echo "===== 3. RUN THE QUERY ====="
/opt/venv/bin/python - <<'PYEOF'
import os
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchTool,
    AzureAISearchToolResource,
    PromptAgentDefinition,
)

project = AIProjectClient(endpoint=os.environ["PROJECT_ENDPOINT"], credential=DefaultAzureCredential())
openai = project.get_openai_client()
conn = project.connections.get(name=os.environ["AI_SEARCH_CONNECTION_NAME"])

# New Foundry (v2): create a prompt agent VERSION, then query via Responses API.
agent = project.agents.create_version(
    agent_name="ai-search-agent-v2",
    definition=PromptAgentDefinition(
        model=os.environ["MODEL_DEPLOYMENT_NAME"],
        instructions=("You are a helpful support assistant. Answer questions using ONLY the "
                      "information returned by the Azure AI Search tool. If the answer is not "
                      "in the search results, say you don't know. Always cite your sources and "
                      "render them as `[message_idx:search_idx\u2020source]`."),
        tools=[
            AzureAISearchTool(
                azure_ai_search=AzureAISearchToolResource(
                    indexes=[
                        AISearchIndexResource(
                            project_connection_id=conn.id,
                            index_name=os.environ["AI_SEARCH_INDEX_NAME"],
                            query_type=AzureAISearchQueryType.SIMPLE,
                            top_k=3,
                        ),
                    ]
                )
            )
        ],
    ),
)
try:
    q = os.environ["QUESTION"]
    print(f"Agent      : {agent.name} (version {agent.version})")
    print(f"Index      : {os.environ['AI_SEARCH_INDEX_NAME']} (via connection {conn.name})")
    print(f"Question   : {q}")
    response = openai.responses.create(
        input=q,
        tool_choice="required",
        extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
    )
    print("\nAnswer:")
    print(response.output_text)
finally:
    project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
PYEOF
