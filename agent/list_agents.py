"""List agents persisted in the Foundry project (new Foundry v2)."""

from __future__ import annotations

import config
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential


def main() -> None:
    project = AIProjectClient(
        endpoint=config.get("PROJECT_ENDPOINT"),
        credential=DefaultAzureCredential(),
    )
    print("Agents currently in the Foundry project (new Foundry v2):")
    count = 0
    for agent in project.agents.list():
        count += 1
        versions = [v.version for v in project.agents.list_versions(agent_name=agent.name)]
        print(f"  - name={agent.name}  versions={versions}")
    if count == 0:
        print("  (none)")


if __name__ == "__main__":
    main()
