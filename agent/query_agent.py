"""Ask the AI Search agent a single question and print the grounded answer.

This is a thin, parameterized version of `create_agent.py` meant for quick
testing from a jump box. Pass your question on the command line:

    python query_agent.py "How long does express shipping take?"

If no question is given, a sample question is used. The script creates a
temporary agent, runs the query, prints the answer (with its AI Search
citation), and deletes the agent.

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
from azure.ai.agents.models import AzureAISearchQueryType, AzureAISearchTool
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

AGENT_NAME = "ai-search-agent-query"
DEFAULT_QUESTION = "What is your warranty, and what does it not cover?"


def main() -> None:
    question = " ".join(sys.argv[1:]).strip() or DEFAULT_QUESTION

    project = AIProjectClient(
        endpoint=config.get("PROJECT_ENDPOINT"),
        credential=DefaultAzureCredential(),
    )
    connection = project.connections.get(name=config.get("AI_SEARCH_CONNECTION_NAME"))

    ai_search = AzureAISearchTool(
        index_connection_id=connection.id,
        index_name=config.index_name(),
        query_type=AzureAISearchQueryType.SIMPLE,
        top_k=3,
    )

    agent = project.agents.create_agent(
        model=config.get("MODEL_DEPLOYMENT_NAME"),
        name=AGENT_NAME,
        instructions=(
            "You are a helpful support assistant. Answer questions using ONLY the "
            "information returned by the Azure AI Search tool. If the answer is not "
            "in the search results, say you don't know."
        ),
        tools=ai_search.definitions,
        tool_resources=ai_search.resources,
    )

    try:
        thread = project.agents.threads.create()
        project.agents.messages.create(thread_id=thread.id, role="user", content=question)
        run = project.agents.runs.create_and_process(thread_id=thread.id, agent_id=agent.id)

        print(f"Index      : {config.index_name()} (via connection {connection.name})")
        print(f"Question   : {question}")
        print(f"Run status : {run.status}")
        if run.status == "failed":
            print(f"Run error  : {run.last_error}")

        for message in project.agents.messages.list(thread_id=thread.id):
            if message.role == "assistant" and message.text_messages:
                print("\nAnswer:")
                print(message.text_messages[-1].text.value)
                break
    finally:
        project.agents.delete_agent(agent.id)


if __name__ == "__main__":
    main()
