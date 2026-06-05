# ============================================================================
# Networking: resource group, virtual network, subnets, and the private DNS
# zones required by Foundry Agent Service private networking.
#
# The official 15b sample is "bring your own VNet + DNS". Here we CREATE the
# VNet, the delegated agent subnet, the private-endpoint subnet, and all six
# private DNS zones (plus their VNet links) so the deployment is self-contained.
# ============================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- Virtual network and subnets ---------------------------------------------

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

# Agent subnet: delegated to Microsoft.App/environments. Required for Standard
# Agent VNet injection. Recommended size /24 because of the delegation.
resource "azurerm_subnet" "agent" {
  name                 = "agent-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.agent_subnet_prefix]

  delegation {
    name = "Microsoft.App.environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private endpoint subnet: hosts the private endpoints for Storage, Cosmos DB,
# AI Search, and the Foundry account.
resource "azurerm_subnet" "private_endpoint" {
  name                 = "pe-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.pe_subnet_prefix]
}

# --- Private DNS zones --------------------------------------------------------
# One zone per service group. These map the public hostnames to the private IPs
# assigned to the private endpoints. Each zone is linked to the VNet so that
# clients inside the VNet (the agent runtime) resolve to private addresses.

locals {
  private_dns_zones = {
    cognitiveservices = "privatelink.cognitiveservices.azure.com"
    openai            = "privatelink.openai.azure.com"
    services_ai       = "privatelink.services.ai.azure.com"
    blob              = "privatelink.blob.core.windows.net"
    search            = "privatelink.search.windows.net"
    cosmos_sql        = "privatelink.documents.azure.com"
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each              = local.private_dns_zones
  name                  = "${each.key}-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = var.tags
}
