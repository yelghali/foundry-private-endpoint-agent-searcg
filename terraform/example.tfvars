# Sample variable values. Copy to terraform.tfvars and adjust.
# The subscription is taken from ARM_SUBSCRIPTION_ID if you leave subscription_id empty.

location            = "eastus2"
search_location     = "eastus"
resource_group_name = "rg-foundry-pe"
name_prefix         = "fdrype"

vnet_address_space  = ["192.168.0.0/16"]
agent_subnet_prefix = "192.168.0.0/24"
pe_subnet_prefix    = "192.168.1.0/24"

model_name     = "gpt-4o"
model_format   = "OpenAI"
model_version  = "2024-11-20"
model_sku      = "GlobalStandard"
model_capacity = 1
