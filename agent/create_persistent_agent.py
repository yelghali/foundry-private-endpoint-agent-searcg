"""Create a PERSISTENT new Foundry (v2) prompt agent (does NOT delete it).

Unlike create_agent.py / query_agent.py (which delete the agent version after
running so nothing is left behind), this script creates the agent and leaves it
in the project so it shows up in the New Foundry portal under "Agents".

Run it from a host that can reach the project endpoint (public access enabled,
or from inside the VNet). Auth: DefaultAzureCredential (az login locally, or a
managed identity on a VM). The identity needs the 'Foundry User' role.

    python create_persistent_agent.py
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


def main() -> None:
    project = AIProjectClient(
        endpoint=config.get("PROJECT_ENDPOINT"),
        credential=DefaultAzureCredential(),
    )
    connection = project.connections.get(name=config.get("AI_SEARCH_CONNECTION_NAME"))

    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=config.get("MODEL_DEPLOYMENT_NAME"),
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

    print(f"Created persistent agent: {agent.name} (version {agent.version})")
    print("It will now appear in the New Foundry portal under Agents.")
    print("Delete later with:")
    print(
        f'  project.agents.delete_version(agent_name="{agent.name}", '
        f'agent_version="{agent.version}")'
    )


if __name__ == "__main__":
    main()
