# Outputs used by the agent script and for verification.

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "location" {
  value = var.location
}

output "foundry_account_name" {
  value = azapi_resource.ai_foundry.name
}

output "foundry_project_name" {
  value = azapi_resource.ai_foundry_project.name
}

# Endpoint used by the Azure AI Projects SDK (AIProjectClient).
output "project_endpoint" {
  description = "Foundry project endpoint for the Azure AI Projects SDK."
  value       = "https://${azapi_resource.ai_foundry.name}.services.ai.azure.com/api/projects/${azapi_resource.ai_foundry_project.name}"
}

output "model_deployment_name" {
  value = azurerm_cognitive_deployment.model.name
}

output "ai_search_name" {
  value = azapi_resource.ai_search.name
}

output "ai_search_endpoint" {
  value = "https://${azapi_resource.ai_search.name}.search.windows.net"
}

# The project connection name to pass to the AI Search agent tool.
output "ai_search_connection_name" {
  value = azapi_resource.conn_aisearch.name
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "agent_subnet_id" {
  value = azurerm_subnet.agent.id
}

output "private_endpoint_subnet_id" {
  value = azurerm_subnet.private_endpoint.id
}

output "private_dns_zone_names" {
  value = [for z in azurerm_private_dns_zone.zones : z.name]
}
