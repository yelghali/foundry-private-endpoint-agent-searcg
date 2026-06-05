# Input variables.

variable "subscription_id" {
  description = "Subscription id to deploy into. Leave empty to use ARM_SUBSCRIPTION_ID."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region. The Foundry account and the VNet must share this region."
  type        = string
  default     = "eastus2"
}

variable "search_location" {
  description = "Region for Azure AI Search. May differ from location (e.g. when the primary region is out of Search capacity). Its private endpoint still lives in the VNet."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the resource group to create for all resources."
  type        = string
  default     = "rg-foundry-pe"
}

variable "name_prefix" {
  description = "Short lowercase prefix used to name resources. 3-10 chars, letters/numbers."
  type        = string
  default     = "fdrype"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.name_prefix))
    error_message = "name_prefix must be 3-10 lowercase letters or digits."
  }
}

# --- Networking ---------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the virtual network."
  type        = list(string)
  default     = ["192.168.0.0/16"]
}

variable "agent_subnet_prefix" {
  description = "Prefix for the agent subnet delegated to Microsoft.App/environments (use /24)."
  type        = string
  default     = "192.168.0.0/24"
}

variable "pe_subnet_prefix" {
  description = "Prefix for the subnet that hosts the private endpoints."
  type        = string
  default     = "192.168.1.0/24"
}

# --- Model deployment ---------------------------------------------------------

variable "model_name" {
  description = "Model to deploy in the Foundry account."
  type        = string
  default     = "gpt-4o"
}

variable "model_format" {
  description = "Model format/publisher."
  type        = string
  default     = "OpenAI"
}

variable "model_version" {
  description = "Model version."
  type        = string
  default     = "2024-11-20"
}

variable "model_sku" {
  description = "Deployment SKU (e.g. GlobalStandard, Standard)."
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "Deployment capacity (thousands of tokens-per-minute)."
  type        = number
  default     = 50
}

variable "tags" {
  description = "Tags applied to the resource group and resources."
  type        = map(string)
  default = {
    workload = "foundry-private-networking"
    sample   = "15b-byovnet-extended"
  }
}
