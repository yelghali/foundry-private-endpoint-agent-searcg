"""Ask the new Foundry (v2) AI Search agent a single question; print the answer.

This uses the **new Foundry Agent Service** (azure-ai-projects >= 2.0.0):
a *prompt agent* created with `project.agents.create_version(...)` and queried
through the OpenAI-compatible **Responses API** (`openai.responses.create`).
This is the "New Foundry" experience (agents have a name + version), NOT the
legacy Assistants API (`create_agent` / `asst_...` ids).

Pass your question on the command line:

    python query_agent.py "How long does express shipping take?"

If no question is given, a sample question is used. The script creates a
temporary agent version, runs the query, prints the grounded answer (with AI
Search citations), and deletes the agent version.

Because the Foundry project and the search service have public network access
DISABLED, run this from a host INSIDE the virtual network (jump box / VM on the
VNet, or via VPN / ExpressRoute / Bastion).

Auth uses Entra ID (DefaultAzureCredential). On a VM with a managed identity no
`az login` is required; elsewhere run `az login` first. The identity needs the
'Foundry User' role on the project.
"""

from __future__ import annotations

import sys

import config
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchTool,
    AzureAISearchToolResource,
    PromptAgentDefinition,
)
from azure.identity import DefaultAzureCredential

AGENT_NAME = "ai-search-agent-v2"
DEFAULT_QUESTION = "What is your warranty, and what does it not cover?"

INSTRUCTIONS = (
    "You are a helpful support assistant. Answer questions using ONLY the "
    "information returned by the Azure AI Search tool. If the answer is not in "
    "the search results, say you don't know. Always cite your sources and render "
    "them as `[message_idx:search_idx\u2020source]`."
)


def main() -> None:
    question = " ".join(sys.argv[1:]).strip() or DEFAULT_QUESTION

    project = AIProjectClient(
        endpoint=config.get("PROJECT_ENDPOINT"),
        credential=DefaultAzureCredential(),
    )
    openai = project.get_openai_client()

    # Resolve the AI Search project connection to its resource id.
    connection = project.connections.get(name=config.get("AI_SEARCH_CONNECTION_NAME"))

    # Create (a new version of) the prompt agent with the AI Search tool.
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=config.get("MODEL_DEPLOYMENT_NAME"),
            instructions=INSTRUCTIONS,
            tools=[
                AzureAISearchTool(
                    azure_ai_search=AzureAISearchToolResource(
                        indexes=[
                            AISearchIndexResource(
                                project_connection_id=connection.id,
                                index_name=config.index_name(),
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
        print(f"Agent      : {agent.name} (version {agent.version})")
        print(f"Index      : {config.index_name()} (via connection {connection.name})")
        print(f"Question   : {question}")

        response = openai.responses.create(
            input=question,
            tool_choice="required",
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )

        print("\nAnswer:")
        print(response.output_text)
    finally:
        project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)


if __name__ == "__main__":
    main()
