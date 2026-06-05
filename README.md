# Foundry Private Networking + AI Search Agent

Deploys a **network-secured Microsoft Foundry Agent Service** environment with
**Bring-Your-Own resources** (Storage, Cosmos DB, AI Search) fully behind
**private endpoints**, creates all required **private DNS zones**, and runs an
**agent that uses the Azure AI Search tool**.

This is based on the official Microsoft sample
[`15b-private-network-standard-agent-setup-byovnet`](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform/15b-private-network-standard-agent-setup-byovnet)
and the docs at
[Set up private networking for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks?tabs=portal).
The official 15b template is *bring-your-own VNet **and** DNS*; this version
**also creates** the VNet, the delegated subnet, the private-endpoint subnet,
and the six private DNS zones, so the whole stack is self-contained.

> **Why this fixes the "can't talk to private AI Search" problem.** When the AI
> Search service has public access disabled, the agent can only reach it over a
> **private endpoint** whose hostname resolves through the
> `privatelink.search.windows.net` **private DNS zone linked to the VNet**. This
> deployment creates that private endpoint, that DNS zone, and the VNet link
> explicitly, and wires the search **private endpoint into the DNS zone group**,
> so name resolution returns a private IP from inside the VNet.

---

## What gets created

**Networking** (`terraform/network.tf`)
- Resource group
- Virtual network `192.168.0.0/16`
- `agent-subnet` `192.168.0.0/24` — delegated to `Microsoft.App/environments`
- `pe-subnet` `192.168.1.0/24` — hosts the private endpoints
- 6 private DNS zones + VNet links:
  - `privatelink.cognitiveservices.azure.com`
  - `privatelink.openai.azure.com`
  - `privatelink.services.ai.azure.com`
  - `privatelink.blob.core.windows.net`
  - `privatelink.search.windows.net`
  - `privatelink.documents.azure.com`

**Foundry + private dependencies** (`terraform/main.tf`)
- Azure Storage (StorageV2, public access disabled, shared-key disabled)
- Azure Cosmos DB (SQL API, public access disabled, local auth disabled)
- Azure AI Search (Standard, public access disabled, AAD auth)
- Foundry account (`AIServices`, public access disabled, **agent VNet
  injection** on the delegated subnet)
- `gpt-4o` model deployment
- Private endpoints for Storage, Cosmos DB, AI Search, and Foundry (each wired
  to the matching DNS zone)
- Foundry project + connections (Cosmos DB, Storage, AI Search — all AAD)
- RBAC for the project identity over the three resources
- **Account** and **project capability hosts** that enable the Standard Agent
  (vector store = AI Search, thread store = Cosmos DB, file store = Storage)

**Agent** (`agent/`)
- `create_index.py` — creates a small AI Search index with sample docs
- `create_agent.py` — creates an agent that uses the **Azure AI Search tool**,
  asks a question, prints the grounded answer

---

## Prerequisites

1. **Azure CLI** and **Terraform >= 1.10** installed.
2. **Python 3.9+** for the agent scripts.
3. Sign in and select the target subscription:
   ```powershell
   az login --tenant <your-tenant-id>
   az account set --subscription <your-subscription-id>
   ```
4. **Register resource providers** (one-time per subscription):
   ```powershell
   az provider register --namespace Microsoft.KeyVault
   az provider register --namespace Microsoft.CognitiveServices
   az provider register --namespace Microsoft.Storage
   az provider register --namespace Microsoft.Search
   az provider register --namespace Microsoft.Network
   az provider register --namespace Microsoft.App
   az provider register --namespace Microsoft.ContainerService
   az provider register --namespace Microsoft.DocumentDB
   ```
5. **Permissions**: Owner *or* (Role Based Access Control Administrator +
   Contributor + Foundry Account Owner) on the subscription/resource group, so
   the deployment can create resources **and** role assignments.

---

## Step-by-step

### 1. Configure variables

```powershell
cd terraform
Copy-Item example.tfvars terraform.tfvars
# edit terraform.tfvars if you want a different region / names
```

Defaults: region `eastus2`, RG `rg-foundry-pe`, VNet `192.168.0.0/16`.

> **Region note:** Class A (`10.x`) ranges are only supported in select regions.
> The default `192.168.x` range works everywhere. The Foundry account and the
> VNet **must** be in the same region. **AI Search may use a different region**
> (`search_location`, default `eastus`) — useful when the primary region is out
> of Search capacity. Its private endpoint still lives in the VNet.

### 2. Deploy the infrastructure

```powershell
$env:ARM_SUBSCRIPTION_ID = "<your-subscription-id>"
terraform init
terraform plan -out tfplan.bin
terraform apply tfplan.bin
```

The capability-host steps include built-in waits for identity/RBAC propagation,
so a full apply takes roughly 15–25 minutes.

> **Capability hosts — naming & idempotency (important).** The **account-level
> Agents capability host is a platform singleton**: the service ignores whatever
> name you PUT and force-names it `"<account-name>@aml_aiagentservice"`. If you
> declare it with a custom name (e.g. `caphostacct`), the resource is still
> created under the canonical name, but the azapi provider then polls the
> non-existent custom-named id until it hits the create timeout (`context
> deadline exceeded`) and rolls the resource out of state — **even though
> provisioning actually succeeded on the backend in ~4 minutes.** This config
> therefore declares the account capability host with the canonical name
> `"${azapi_resource.ai_foundry.name}@aml_aiagentservice"` so azapi PUTs and
> polls the exact id the service uses. The **project** capability host keeps its
> declared name (`caphostproj`) normally.
>
> Capability hosts are also **immutable** — the service rejects any PUT *update*
> with HTTP 400 (`RequestInvalid`). Both capability-host resources therefore set
> `lifecycle { ignore_changes = all }` so Terraform never attempts an update
> after create. Both also set `timeouts { create = "60m" }` as a safety margin.
>
> If you are recovering a deployment where the account capability host already
> exists on the backend but is missing from state (because an earlier run timed
> out), import it instead of recreating it:
>
> ```powershell
> $acct = "<account-name>"                       # e.g. fdrype6990
> $rg   = "rg-foundry-pe"
> $sub  = $env:ARM_SUBSCRIPTION_ID
> terraform import azapi_resource.ai_foundry_account_capability_host `
>   "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$acct/capabilityHosts/$acct@aml_aiagentservice?api-version=2025-04-01-preview"
> terraform import azapi_resource.ai_foundry_project_capability_host `
>   "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$acct/projects/<project-name>/capabilityHosts/caphostproj?api-version=2025-04-01-preview"
> ```
>
> A normal apply otherwise takes roughly 10–20 minutes once the capability hosts
> are tracked correctly. (`terraform plan` may still report a single cosmetic
> in-place update of the Foundry account — an azapi normalization no-op.)

### 3. Verify the deployment

- **Subnet delegation** — `agent-subnet` shows delegation to
  `Microsoft.App/environments`.
- **Public access disabled** — Foundry, AI Search, Storage, Cosmos DB.
- **DNS resolution** — from a host **inside the VNet**:
  ```powershell
  terraform output
  nslookup <ai_search_name>.search.windows.net   # must return a 192.168.x IP
  nslookup <foundry_account_name>.services.ai.azure.com
  ```
  Each name must resolve to a **private** IP. If it resolves to a public IP, the
  DNS zone link or the private endpoint DNS zone group is missing.

### 4. Get connectivity into the VNet

Because everything is private, you reach the project and search **only from
inside the VNet**. Use one of:
- A **VM / jump box** on the VNet (optionally via **Azure Bastion**)
- **Azure VPN Gateway** (point-to-site or site-to-site)
- **Azure ExpressRoute**

Run steps 5–6 from that host (or any machine with private connectivity).

### 5. Create the AI Search index

```powershell
cd ../agent
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
az login                       # identity needs Search Index Data Contributor + Search Service Contributor
python create_index.py
```

`create_index.py` reads the search endpoint/index from the Terraform outputs and
uploads three sample support documents.

### 6. Create and run the AI Search agent

```powershell
# identity needs the 'Foundry User' role on the project
python create_agent.py
```

`create_agent.py`:
1. Connects to the project (`project_endpoint`).
2. Resolves the **AI Search project connection** to its resource id.
3. Builds an `AzureAISearchTool` over the index.
4. Creates the agent, asks a question, and prints the grounded answer.

Configuration is auto-read from `terraform output`; override any value with
environment variables (`PROJECT_ENDPOINT`, `MODEL_DEPLOYMENT_NAME`,
`AI_SEARCH_CONNECTION_NAME`, `AI_SEARCH_ENDPOINT`, `AI_SEARCH_INDEX_NAME`).

### Test a query from the jump box (no SSH required)

[`agent/jumpbox_query.sh`](agent/jumpbox_query.sh) is a **self-contained** test
script: it bootstraps a Python venv on the jump box, resolves the AI Search
connection, creates a temporary agent, asks one question, prints the grounded
answer (with its `【…†source】` citation), and deletes the agent. Auth uses the
**VM's managed identity** — no `az login` on the box.

The jump box identity needs `Foundry User` on the project and `Search Index Data
Contributor` on the search service. Get the config values from
`terraform output`.

**Run the default sample question** (`az vm run-command` — runs the script on the
VM and returns its output to you):

```powershell
$rg = "rg-foundry-pe"; $vm = "jumpbox"
$proj   = terraform -chdir=terraform output -raw project_endpoint
$search = terraform -chdir=terraform output -raw ai_search_connection_name

az vm run-command invoke -g $rg -n $vm --command-id RunShellScript `
  --scripts "@agent/jumpbox_query.sh" `
  --parameters "PROJECT_ENDPOINT=$proj" "AI_SEARCH_CONNECTION_NAME=$search" `
  --query "value[].message" -o tsv
```

**Ask your own question.** `az vm run-command` can't pass values with spaces, so
send the question **base64-encoded** as `QUESTION_B64` (the script decodes it):

```powershell
$q = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("How long does express shipping take?"))

az vm run-command invoke -g $rg -n $vm --command-id RunShellScript `
  --scripts "@agent/jumpbox_query.sh" `
  --parameters "PROJECT_ENDPOINT=$proj" "AI_SEARCH_CONNECTION_NAME=$search" "QUESTION_B64=$q" `
  --query "value[].message" -o tsv
```

Expected output (DNS resolves to **192.168.x** private IPs, run completes, and
the answer carries a citation):

```text
===== 1. PRIVATE DNS RESOLUTION (expect 192.168.x private IPs) =====
   fdrype6990search.search.windows.net           -> 192.168.1.7
   fdrype6990.services.ai.azure.com              -> 192.168.1.10
===== 3. RUN THE QUERY =====
Index      : agent-sample-index (via connection fdrype6990search)
Question   : How long does express shipping take?
Run status : completed

Answer:
Express shipping takes 1-2 business days【3:0†source】.
```

> **Interactive alternative.** If you have **Azure Bastion** or SSH into the box,
> activate the venv and call the parameterized helper directly:
> ```bash
> export PROJECT_ENDPOINT="$(terraform -chdir=terraform output -raw project_endpoint)"
> export AI_SEARCH_CONNECTION_NAME="$(terraform -chdir=terraform output -raw ai_search_connection_name)"
> /opt/venv/bin/python agent/query_agent.py "How long does express shipping take?"
> ```

### Example run — query, REST calls, and grounded response

The following is a **real, captured run** of the agent from inside the VNet
(secrets such as bearer tokens are redacted; resource names are kept so you can
see the URL shape). The agent is given a question, it calls the **Azure AI
Search tool** against the private index, and returns a grounded answer with a
citation.

**The query**

```text
What is your warranty, and what does it not cover?
```

**The REST API calls the SDK makes** (all against the *private* Foundry data
plane at `https://<account>.services.ai.azure.com`, reachable only inside the
VNet). `Authorization: Bearer` headers are `REDACTED` by the SDK logger:

```http
GET    https://fdrype6990.services.ai.azure.com/api/projects/project6990/connections/fdrype6990search?api-version=...
POST   https://fdrype6990.services.ai.azure.com/api/projects/project6990/assistants?api-version=v1
POST   https://fdrype6990.services.ai.azure.com/api/projects/project6990/threads?api-version=v1
POST   https://fdrype6990.services.ai.azure.com/api/projects/project6990/threads/{thread_id}/messages?api-version=v1
POST   https://fdrype6990.services.ai.azure.com/api/projects/project6990/threads/{thread_id}/runs?api-version=v1
GET    https://fdrype6990.services.ai.azure.com/api/projects/project6990/threads/{thread_id}/runs/{run_id}/steps?api-version=v1
DELETE https://fdrype6990.services.ai.azure.com/api/projects/project6990/assistants/{agent_id}?api-version=v1

Request headers (every call):
    Accept: application/json
    User-Agent: AIProjectClient azsdk-python-ai-agents/1.1.0 Python/3.10.12 (Linux-x86_64)
    Authorization: REDACTED
Response status: 200
```

**The AI Search tool call** (inside the run step) — note it reads the document
straight from the **private** search endpoint
`https://<search>.search.windows.net`:

```json
{
  "type": "azure_ai_search",
  "azure_ai_search": {
    "input": "\"warranty coverage\"",
    "output": {
      "summary": "Retrieved 1 documents.",
      "metadata": {
        "titles": ["Warranty"],
        "ids": ["3"],
        "get_urls": [
          "https://fdrype6990search.search.windows.net/indexes/agent-sample-index/docs/3?api-version=2024-07-01&$select=id,title,content"
        ],
        "command": "search",
        "query_type": "simple",
        "top_k": 3
      }
    }
  }
}
```

**The response**

```text
Agent id    : asst_xxxxxxxxxxxxxxxxxxxxxxxx
Model       : gpt-4o
Index       : agent-sample-index  (private, via connection fdrype6990search)
RUN STATUS  : completed

AGENT ANSWER:
The warranty provided is a 1-year limited warranty that covers manufacturing
defects. However, it does not cover accidental damage【3:0†source】.

TOOL CALLS (proof the answer came from the AI Search index):
  - tool: azure_ai_search
```

The `【3:0†source】` citation and the `azure_ai_search` tool call confirm the
answer was grounded on document `3` (*"Warranty"*) in the private index, not on
the model's parametric knowledge. The underlying index document is *"All
hardware products include a 1-year limited warranty that covers manufacturing
defects but not accidental damage."*

---

## Architecture

```
Secure access (VPN / ExpressRoute / Bastion)
                  │
        ┌─────────▼──────────┐
        │  Foundry account   │  publicNetworkAccess = Disabled
        │  + Foundry project │
        └─────────┬──────────┘
                  │ agent VNet injection (subnet delegation)
   ┌──────────────▼───────────────────────────────────┐
   │ VNet 192.168.0.0/16                               │
   │  agent-subnet 192.168.0.0/24  → Microsoft.App/env │
   │  pe-subnet    192.168.1.0/24                       │
   │     ├─ PE → Storage  (privatelink.blob…)          │
   │     ├─ PE → Cosmos   (privatelink.documents…)     │
   │     ├─ PE → Search   (privatelink.search…)        │
   │     └─ PE → Foundry  (privatelink.cognitiveservices / openai / services.ai)
   └───────────────────────────────────────────────────┘
```

| Service | Sub-resource | Private DNS zone |
|---|---|---|
| Foundry | `account` | `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` |
| AI Search | `searchService` | `privatelink.search.windows.net` |
| Cosmos DB | `Sql` | `privatelink.documents.azure.com` |
| Storage | `blob` | `privatelink.blob.core.windows.net` |

---

## Troubleshooting (private AI Search)

- **Agent run fails reaching search / index not found** — confirm the
  `privatelink.search.windows.net` zone is **linked to the VNet** and the search
  private endpoint has a **DNS zone group** (both are created here). From inside
  the VNet, `nslookup <search>.search.windows.net` must return `192.168.x`.
- **`401`/auth errors from search** — the project identity needs *Search Index
  Data Contributor* + *Search Service Contributor* (created by Terraform); your
  *user* needs the same to run `create_index.py`.
- **`rate_limit_exceeded` on the agent run** — the model deployment capacity
  (`var.model_capacity`, thousands of tokens-per-minute) is too low. The default
  here is `50`; a capacity of `1` will 429 immediately. Raise `model_capacity`
  and re-apply, or bump the deployment in the portal.
- **`CreateCapabilityHost… single, non-empty value`** — all three BYO
  connections (Storage, Cosmos, Search) must exist before the project capability
  host; the dependencies here enforce that ordering.
- **`context deadline exceeded` on the account capability host** — azapi timed
  out *tracking* the create, almost always because of the singleton naming
  described in step 2 (the service created `"<account>@aml_aiagentservice"` while
  azapi polled a custom name). Verify the resource really exists on the backend
  with `az rest --method get --url ".../accounts/<account>/capabilityHosts?api-version=2025-04-01-preview"`;
  if it is `Succeeded`, **import** it (see step 2) rather than recreating. Also
  confirm `agent-subnet` is delegated to `Microsoft.App/environments` and the
  account's `networkInjections` `subnetArmId` matches that subnet.
- **`RequestInvalid` / HTTP 400 updating a capability host** — capability hosts
  are immutable; this config sets `lifecycle { ignore_changes = all }` on both to
  prevent update PUTs. If you still see it, your state drifted before that block
  was added — re-import the capability host to refresh state.
- **Conditional forwarders** — if you use custom DNS servers, forward the four
  zones above to the Azure DNS virtual server `168.63.129.16`.

---

## Cleanup

```powershell
cd terraform
terraform destroy
```

> **Important:** To reuse the same delegated agent subnet later, you must
> **delete *and purge*** the Foundry account so its capability host fully
> unlinks (allow ~20 min). Simply deleting is not enough — see
> [Recover/purge resources](https://learn.microsoft.com/en-us/azure/ai-services/recover-purge-resources#purge-a-deleted-resource).

---

## Files

```
terraform/
  versions.tf      provider + Terraform version constraints
  providers.tf     azapi / azurerm provider config
  variables.tf     inputs (region, names, CIDRs, model)
  data.tf          azurerm_client_config
  network.tf       RG, VNet, subnets, 6 private DNS zones + links
  main.tf          Storage, Cosmos, Search, Foundry, PEs, project, RBAC, caphosts
  locals.tf        project workspace GUID
  outputs.tf       endpoints + names consumed by the agent scripts
  example.tfvars   sample variable values
agent/
  requirements.txt Python deps
  config.py        reads config from env or `terraform output`
  create_index.py  creates an AI Search index + sample docs
  create_agent.py  creates/runs the agent using the Azure AI Search tool
  query_agent.py   asks one question (CLI arg) and prints the grounded answer
  jumpbox_query.sh self-contained jump-box test (via `az vm run-command`)
```
