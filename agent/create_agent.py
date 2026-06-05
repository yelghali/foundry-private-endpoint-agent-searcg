"""Create a Foundry agent that uses the Azure AI Search tool, then run it.

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
from azure.ai.agents.models import AzureAISearchQueryType, AzureAISearchTool
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

AGENT_NAME = "ai-search-agent"
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

    # Resolve the AI Search project connection to its resource id.
    connection = project.connections.get(name=connection_name)

    ai_search = AzureAISearchTool(
        index_connection_id=connection.id,
        index_name=index,
        query_type=AzureAISearchQueryType.SIMPLE,
        top_k=3,
    )

    agent = project.agents.create_agent(
        model=model,
        name=AGENT_NAME,
        instructions=(
            "You are a helpful support assistant. Answer questions using ONLY the "
            "information returned by the Azure AI Search tool. If the answer is not "
            "in the search results, say you don't know."
        ),
        tools=ai_search.definitions,
        tool_resources=ai_search.resources,
    )
    print(f"Created agent: {agent.id}")

    thread = project.agents.threads.create()
    project.agents.messages.create(thread_id=thread.id, role="user", content=QUESTION)

    run = project.agents.runs.create_and_process(thread_id=thread.id, agent_id=agent.id)
    print(f"Run status: {run.status}")
    if run.status == "failed":
        print(f"Run error: {run.last_error}")

    messages = project.agents.messages.list(thread_id=thread.id)
    for message in messages:
        if message.role == "assistant" and message.text_messages:
            print("\nAssistant:")
            print(message.text_messages[-1].text.value)

    # Comment out the next line to keep the agent for reuse.
    project.agents.delete_agent(agent.id)
    print(f"\nDeleted agent: {agent.id}")


if __name__ == "__main__":
    main()
