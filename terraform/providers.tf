# Provider configuration.
# This deployment targets a single subscription. The subscription id is read
# from the ARM_SUBSCRIPTION_ID environment variable (set before running, see
# README) or from the optional subscription_id variable.

provider "azapi" {
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
}

provider "azurerm" {
  subscription_id     = var.subscription_id != "" ? var.subscription_id : null
  storage_use_azuread = true
  features {}
}
