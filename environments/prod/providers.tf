# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : prod
# Fichier : providers.tf
# Description : Configuration du provider azurerm pour l'environnement prod.
#               Les credentials du Service Principal sont passés explicitement
#               depuis les variables Terraform Cloud (sensitives).
#               Sans cette configuration, le provider tenterait de trouver
#               l'Azure CLI en fallback — absent dans l'environnement TFC.
#               Ces 4 variables sont injectées par scripts/setup-azure.sh.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# Les credentials sont configurés comme variables sensitives dans TFC.
# Jamais dans terraform.tfvars ni dans le code source.
provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret

  features {
    key_vault {
      # Permettre la suppression du Key Vault sans attendre la période
      # de rétention soft-delete — utile en environnement d'apprentissage.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # Permettre la suppression du resource group même s'il contient des ressources.
      prevent_deletion_if_contains_resources = false
    }
  }
}
