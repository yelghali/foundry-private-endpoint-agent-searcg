# Terraform and provider version constraints.
# Based on the official Microsoft Foundry sample 15b (BYO VNet) which requires
# both the AzAPI and AzureRM providers.
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.5"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.37"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Uncomment to store state remotely in an Azure Storage account.
  # backend "azurerm" {}
}
