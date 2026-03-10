# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : main.tf
# Description : Azure Key Vault avec RBAC activé. Accès public ouvert pour
#               permettre à Terraform Cloud (runner externe au VNet) d'écrire
#               les secrets lors de l'apply. La VM Flask accède à Key Vault
#               exclusivement via Private Endpoint (résolution DNS privée).
#               La protection est assurée par RBAC — pas par l'IP filtering.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

locals {
  prefix = "${var.project_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "key-vault"
    environment = var.environment
    phase       = "8c"
    managed_by  = "terraform"
  })
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                = "${var.project_prefix}-${var.environment}-kv"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization = true

  # Accès public activé — nécessaire pour que Terraform Cloud puisse
  # créer les secrets lors de l'apply. La VM Flask accède à Key Vault
  # via Private Endpoint — son DNS résout le FQDN en IP privée.
  # La protection est assurée par RBAC exclusivement.
  public_network_access_enabled = true

  soft_delete_retention_days = 7
  purge_protection_enabled   = var.purge_protection_enabled

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = local.common_tags
}
