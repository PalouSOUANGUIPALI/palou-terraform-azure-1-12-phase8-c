# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : private-endpoint.tf
# Description : Private Endpoint pour Key Vault dans snet-pe.
#               La VM Flask résout le FQDN Key Vault en IP privée via
#               la zone DNS privatelink.vaultcore.azure.net liée au VNet.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-kv-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-kv-${local.prefix}"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-kv-${local.prefix}"
    private_dns_zone_ids = [var.private_dns_zone_keyvault_id]
  }
}
