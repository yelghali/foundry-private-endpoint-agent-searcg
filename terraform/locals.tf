locals {
  # Derive the project workspace GUID (used for container-scoped RBAC
  # conditions) from the project's internalId, matching the official sample.
  project_id_guid = format(
    "%s-%s-%s-%s-%s",
    substr(azapi_resource.ai_foundry_project.output.properties.internalId, 0, 8),
    substr(azapi_resource.ai_foundry_project.output.properties.internalId, 8, 4),
    substr(azapi_resource.ai_foundry_project.output.properties.internalId, 12, 4),
    substr(azapi_resource.ai_foundry_project.output.properties.internalId, 16, 4),
    substr(azapi_resource.ai_foundry_project.output.properties.internalId, 20, 12),
  )
}
