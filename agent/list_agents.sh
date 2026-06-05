#!/usr/bin/env bash
# List agents currently persisted in the Foundry project (proves these are
# real server-side new Foundry v2 agents, not local/OpenAI objects). Uses the
# new Foundry Agent Service SDK (azure-ai-projects >= 2.0.0).
set -euo pipefail
export PROJECT_ENDPOINT="https://fdrype6990.services.ai.azure.com/api/projects/project6990"
/opt/venv/bin/pip install --quiet "azure-identity>=1.17.0" "azure-ai-projects>=2.0.0"
/opt/venv/bin/python - <<'PYEOF'
import os
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
p = AIProjectClient(endpoint=os.environ["PROJECT_ENDPOINT"], credential=DefaultAzureCredential())
print("Agents currently in the Foundry project (new Foundry v2):")
n = 0
for a in p.agents.list():
    n += 1
    versions = [v.version for v in p.agents.list_versions(agent_name=a.name)]
    print(f"  - name={a.name}  versions={versions}")
if n == 0:
    print("  (none - test scripts delete their agent version after each run)")
PYEOF
