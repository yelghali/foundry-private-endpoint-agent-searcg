# ============================================================================
# Foundry private deployment (adapted from official sample 15b).
#
# Creates: Storage, Cosmos DB, AI Search, the Foundry (AIServices) account with
# agent VNet injection, a model deployment, private endpoints (wired to the DNS
# zones created in network.tf), the Foundry project, project connections, the
# RBAC assignments, and the account/project capability hosts that enable the
# Standard Agent.
# ============================================================================

resource "random_string" "unique" {
  length      = 4
  min_numeric = 4
  numeric     = true
  special     = false
  lower       = true
  upper       = false
}

# ---------------------------------------------------------------------------
# Agent data dependencies: Storage, Cosmos DB, AI Search
# ---------------------------------------------------------------------------

# Storage account for agent file data.
resource "azurerm_storage_account" "storage_account" {
  name                = "${var.name_prefix}${random_string.unique.result}stg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS"

  # Force Entra ID auth; disable shared key access.
  shared_access_key_enabled = false

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

# Cosmos DB account for agent thread/conversation storage.
resource "azurerm_cosmosdb_account" "cosmosdb" {
  name                = "${var.name_prefix}${random_string.unique.result}cosmos"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  offer_type        = "Standard"
  kind              = "GlobalDocumentDB"
  free_tier_enabled = false

  local_authentication_disabled = true
  public_network_access_enabled = false

  automatic_failover_enabled       = false
  multiple_write_locations_enabled = false

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }

  tags = var.tags
}

# AI Search service for agent vector stores. Public access disabled so it is
# only reachable through its private endpoint inside the VNet.
resource "azapi_resource" "ai_search" {
  type                      = "Microsoft.Search/searchServices@2025-05-01"
  name                      = "${var.name_prefix}${random_string.unique.result}search"
  parent_id                 = azurerm_resource_group.rg.id
  location                  = var.search_location
  schema_validation_enabled = true

  body = {
    sku = {
      name = "standard"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      replicaCount   = 1
      partitionCount = 1
      hostingMode    = "Default"
      semanticSearch = "disabled"

      disableLocalAuth = false
      authOptions = {
        aadOrApiKey = {
          aadAuthFailureMode = "http401WithBearerChallenge"
        }
      }

      publicNetworkAccess = "Disabled"
      networkRuleSet = {
        bypass = "None"
      }
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Foundry account (AIServices) with agent VNet injection
# ---------------------------------------------------------------------------

resource "azapi_resource" "ai_foundry" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name                      = "${var.name_prefix}${random_string.unique.result}"
  parent_id                 = azurerm_resource_group.rg.id
  location                  = var.location
  schema_validation_enabled = false

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      # Support both Entra ID and key auth on the underlying account.
      disableLocalAuth = false

      # Mark this as a Foundry resource that can host projects.
      allowProjectManagement = true

      # Custom subdomain is required for private DNS / token auth.
      customSubDomainName = "${var.name_prefix}${random_string.unique.result}"

      # Disable public access; allow trusted Azure services.
      publicNetworkAccess = "Disabled"
      networkAcls = {
        defaultAction = "Allow"
      }

      # VNet injection for Standard Agents: bind the agent runtime to the
      # delegated agent subnet.
      networkInjections = [
        {
          scenario                   = "agent"
          subnetArmId                = azurerm_subnet.agent.id
          useMicrosoftManagedNetwork = false
        }
      ]
    }
  }

  tags = var.tags
}

# Model deployment used by the agent.
resource "azurerm_cognitive_deployment" "model" {
  depends_on           = [azapi_resource.ai_foundry]
  name                 = var.model_name
  cognitive_account_id = azapi_resource.ai_foundry.id

  sku {
    name     = var.model_sku
    capacity = var.model_capacity
  }

  model {
    format  = var.model_format
    name    = var.model_name
    version = var.model_version
  }
}

# ---------------------------------------------------------------------------
# Private endpoints (wired to the private DNS zones from network.tf)
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "pe_storage" {
  name                = "${azurerm_storage_account.storage_account.name}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${azurerm_storage_account.storage_account.name}-plsc"
    private_connection_resource_id = azurerm_storage_account.storage_account.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-dns-config"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["blob"].id]
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "pe_cosmosdb" {
  depends_on          = [azurerm_private_endpoint.pe_storage]
  name                = "${azurerm_cosmosdb_account.cosmosdb.name}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${azurerm_cosmosdb_account.cosmosdb.name}-plsc"
    private_connection_resource_id = azurerm_cosmosdb_account.cosmosdb.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "cosmos-dns-config"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["cosmos_sql"].id]
  }

  tags = var.tags
}

# AI Search private endpoint. This is the path that makes the *private* search
# service reachable from the agent runtime and resolvable via
# privatelink.search.windows.net.
resource "azurerm_private_endpoint" "pe_aisearch" {
  depends_on          = [azurerm_private_endpoint.pe_cosmosdb]
  name                = "${azapi_resource.ai_search.name}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${azapi_resource.ai_search.name}-plsc"
    private_connection_resource_id = azapi_resource.ai_search.id
    subresource_names              = ["searchService"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "search-dns-config"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["search"].id]
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "pe_aifoundry" {
  depends_on          = [azurerm_private_endpoint.pe_aisearch]
  name                = "${azapi_resource.ai_foundry.name}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${azapi_resource.ai_foundry.name}-plsc"
    private_connection_resource_id = azapi_resource.ai_foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "foundry-dns-config"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.zones["cognitiveservices"].id,
      azurerm_private_dns_zone.zones["services_ai"].id,
      azurerm_private_dns_zone.zones["openai"].id,
    ]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Foundry project, connections, RBAC, and capability hosts
# ---------------------------------------------------------------------------

resource "azapi_resource" "ai_foundry_project" {
  depends_on = [
    azapi_resource.ai_foundry,
    azurerm_private_endpoint.pe_storage,
    azurerm_private_endpoint.pe_cosmosdb,
    azurerm_private_endpoint.pe_aisearch,
    azurerm_private_endpoint.pe_aifoundry,
  ]

  type                      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name                      = "project${random_string.unique.result}"
  parent_id                 = azapi_resource.ai_foundry.id
  location                  = var.location
  schema_validation_enabled = false

  body = {
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      displayName = "project"
      description = "Network-secured Foundry project with Standard Agent"
    }
  }

  response_export_values = [
    "identity.principalId",
    "properties.internalId",
  ]
}

# Allow the project's system-assigned identity to propagate through Entra ID.
resource "time_sleep" "wait_project_identities" {
  depends_on      = [azapi_resource.ai_foundry_project]
  create_duration = "10s"
}

# Project connection: Cosmos DB (thread storage).
resource "azapi_resource" "conn_cosmosdb" {
  depends_on                = [azapi_resource.ai_foundry_project]
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azurerm_cosmosdb_account.cosmosdb.name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    name = azurerm_cosmosdb_account.cosmosdb.name
    properties = {
      category = "CosmosDb"
      target   = azurerm_cosmosdb_account.cosmosdb.endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_cosmosdb_account.cosmosdb.id
        location   = var.location
      }
    }
  }
}

# Project connection: Storage (file storage).
resource "azapi_resource" "conn_storage" {
  depends_on                = [azapi_resource.ai_foundry_project]
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azurerm_storage_account.storage_account.name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    name = azurerm_storage_account.storage_account.name
    properties = {
      category = "AzureStorageAccount"
      target   = azurerm_storage_account.storage_account.primary_blob_endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_storage_account.storage_account.id
        location   = var.location
      }
    }
  }
}

# Project connection: AI Search (vector store). This is the connection the
# AI Search agent tool uses.
resource "azapi_resource" "conn_aisearch" {
  depends_on                = [azapi_resource.ai_foundry_project]
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azapi_resource.ai_search.name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    name = azapi_resource.ai_search.name
    properties = {
      category = "CognitiveSearch"
      target   = "https://${azapi_resource.ai_search.name}.search.windows.net"
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ApiVersion = "2025-05-01-preview"
        ResourceId = azapi_resource.ai_search.id
        location   = var.search_location
      }
    }
  }
}

# --- Account-level RBAC for the project identity over BYO resources ----------

resource "azurerm_role_assignment" "cosmosdb_operator" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_foundry_project.name}${azapi_resource.ai_foundry_project.output.identity.principalId}${azurerm_resource_group.rg.name}cosmosdboperator")
  scope                = azurerm_cosmosdb_account.cosmosdb.id
  role_definition_name = "Cosmos DB Operator"
  principal_id         = azapi_resource.ai_foundry_project.output.identity.principalId
}

resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_foundry_project.name}${azapi_resource.ai_foundry_project.output.identity.principalId}${azurerm_storage_account.storage_account.name}storageblobdatacontributor")
  scope                = azurerm_storage_account.storage_account.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azapi_resource.ai_foundry_project.output.identity.principalId
}

resource "azurerm_role_assignment" "search_index_data_contributor" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_foundry_project.name}${azapi_resource.ai_foundry_project.output.identity.principalId}${azapi_resource.ai_search.name}searchindexdatacontributor")
  scope                = azapi_resource.ai_search.id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = azapi_resource.ai_foundry_project.output.identity.principalId
}

resource "azurerm_role_assignment" "search_service_contributor" {
  depends_on           = [time_sleep.wait_project_identities]
  name                 = uuidv5("dns", "${azapi_resource.ai_foundry_project.name}${azapi_resource.ai_foundry_project.output.identity.principalId}${azapi_resource.ai_search.name}searchservicecontributor")
  scope                = azapi_resource.ai_search.id
  role_definition_name = "Search Service Contributor"
  principal_id         = azapi_resource.ai_foundry_project.output.identity.principalId
}

# Allow RBAC to propagate before creating the capability host.
resource "time_sleep" "wait_rbac" {
  depends_on = [
    azurerm_role_assignment.cosmosdb_operator,
    azurerm_role_assignment.storage_blob_data_contributor,
    azurerm_role_assignment.search_index_data_contributor,
    azurerm_role_assignment.search_service_contributor,
  ]
  create_duration = "60s"
}

# Account capability host. In a BYO-VNet (network-injected) setup the account
# capability host MUST declare the delegated agent subnet via `customerSubnet`,
# and it must match the subnet recorded on the Foundry account's networkInjection.
#
# NOTE ON NAMING: the account-level *Agents* capability host is a platform
# singleton. The backend ignores any custom name and force-names it
# "<account-name>@aml_aiagentservice". If you PUT a different name (e.g.
# "caphostacct"), the resource is still created under the canonical name, but
# the azapi provider then polls the (non-existent) custom-named id until it hits
# the create timeout, even though provisioning actually succeeded in minutes.
# We therefore declare the resource with the canonical name so azapi PUTs and
# polls the exact id the backend uses.
resource "azapi_resource" "ai_foundry_account_capability_host" {
  depends_on                = [time_sleep.wait_rbac]
  type                      = "Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview"
  name                      = "${azapi_resource.ai_foundry.name}@aml_aiagentservice"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind = "Agents"
      customerSubnet     = azurerm_subnet.agent.id
    }
  }

  # The account capability host provisions the managed agent network/compute
  # (a Container Apps managed environment in the delegated subnet) which can
  # take well over the azapi 30-minute default. Allow up to 1 hour.
  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  # Capability hosts are immutable: the service rejects PUT updates with HTTP 400
  # (RequestInvalid). Ignore all post-create drift so Terraform never attempts an
  # update once the resource exists.
  lifecycle {
    ignore_changes = all
  }
}

# Project capability host: binds the agent runtime to the three BYO resources.
resource "azapi_resource" "ai_foundry_project_capability_host" {
  depends_on = [
    azapi_resource.conn_aisearch,
    azapi_resource.conn_cosmosdb,
    azapi_resource.conn_storage,
    azapi_resource.ai_foundry_account_capability_host,
    time_sleep.wait_rbac,
  ]

  type                      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview"
  name                      = "caphostproj"
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind     = "Agents"
      vectorStoreConnections = [azapi_resource.ai_search.name]
      storageConnections     = [azurerm_storage_account.storage_account.name]
      threadStorageConnections = [
        azurerm_cosmosdb_account.cosmosdb.name
      ]
    }
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  # Capability hosts are immutable: the service rejects PUT updates with HTTP 400
  # (RequestInvalid). Ignore all post-create drift so Terraform never attempts an
  # update once the resource exists.
  lifecycle {
    ignore_changes = all
  }
}

# --- Data-plane RBAC created after the capability host provisions containers --

resource "azurerm_cosmosdb_sql_role_assignment" "cosmosdb_data_contributor" {
  depends_on          = [azapi_resource.ai_foundry_project_capability_host]
  name                = uuidv5("dns", "${azapi_resource.ai_foundry_project.name}${azapi_resource.ai_foundry_project.output.identity.principalId}cosmosdbdbsqlrole")
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb.name
  scope               = azurerm_cosmosdb_account.cosmosdb.id
  role_definition_id  = "${azurerm_cosmosdb_account.cosmosdb.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azapi_resource.ai_foundry_project.output.identity.principalId
}

resource "azurerm_role_assignment" "storage_blob_data_owner" {
  depends_on           = [azapi_resource.ai_foundry_project_capability_host]
  name                 = uuidv5("dns", "${azapi_resource.ai_foundry_project.name}${azapi_resource.ai_foundry_project.output.identity.principalId}${azurerm_storage_account.storage_account.name}storageblobdataowner")
  scope                = azurerm_storage_account.storage_account.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azapi_resource.ai_foundry_project.output.identity.principalId

  condition_version = "2.0"
  condition         = <<-EOT
  (
    (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'})
    )
    OR
    (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase '${local.project_id_guid}'
      AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase '*-azureml-agent')
  )
  EOT
}
