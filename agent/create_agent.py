"""Create a new Foundry (v2) prompt agent that uses the Azure AI Search tool.

This uses the **new Foundry Agent Service** (azure-ai-projects >= 2.0.0):
the agent is created with `project.agents.create_version(...)` and queried
through the OpenAI-compatible **Responses API** (`openai.responses.create`).
This is the "New Foundry" experience (agents have a name + version), NOT the
legacy Assistants API (`create_agent` / `asst_...` ids).

The agent grounds its answers on documents in your private Azure AI Search index
through the project's AI Search connection.

Because the Foundry project and the search service have public network access
DISABLED, this script must run from a host INSIDE the virtual network (jump box
/ VM on the VNet, or via VPN / ExpressRoute / Bastion).

Auth uses Entra ID (DefaultAzureCredential). Run `az login` first and ensure the
identity has the 'Foundry User' role on the project.
"""

from __future__ import annotations

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
QUESTION = "What is the refund policy and how long does a refund take?"


def main() -> None:
    project_endpoint = config.get("PROJECT_ENDPOINT")
    model = config.get("MODEL_DEPLOYMENT_NAME")
    connection_name = config.get("AI_SEARCH_CONNECTION_NAME")
    index = config.index_name()

    project = AIProjectClient(
        endpoint=project_endpoint,
        credential=DefaultAzureCredential(),
    )
    openai = project.get_openai_client()

    # Resolve the AI Search project connection to its resource id.
    connection = project.connections.get(name=connection_name)

    # Create (a new version of) the prompt agent with the AI Search tool.
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=model,
            instructions=(
                "You are a helpful support assistant. Answer questions using ONLY the "
                "information returned by the Azure AI Search tool. If the answer is not "
                "in the search results, say you don't know. Always cite your sources and "
                "render them as `[message_idx:search_idx\u2020source]`."
            ),
            tools=[
                AzureAISearchTool(
                    azure_ai_search=AzureAISearchToolResource(
                        indexes=[
                            AISearchIndexResource(
                                project_connection_id=connection.id,
                                index_name=index,
                                query_type=AzureAISearchQueryType.SIMPLE,
                                top_k=3,
                            ),
                        ]
                    )
                )
            ],
        ),
    )
    print(f"Created agent: {agent.name} (version {agent.version})")

    response = openai.responses.create(
        input=QUESTION,
        tool_choice="required",
        extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
    )
    print("\nAssistant:")
    print(response.output_text)

    # Comment out the next line to keep the agent for reuse in the portal.
    project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
    print(f"\nDeleted agent: {agent.name} (version {agent.version})")


if __name__ == "__main__":
    main()
