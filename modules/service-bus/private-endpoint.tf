# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
# Fichier : private-endpoint.tf
# Description : Private Endpoint pour le Service Bus Namespace.
#               Utilise la zone DNS privatelink.servicebus.windows.net
#               partagée avec Event Hub — les deux services utilisent
#               la même zone DNS privée.
#               Le Private Endpoint n'est disponible qu'en SKU Premium —
#               cette ressource est donc conditionnelle :
#                 dev/staging (Standard) → pas de PE, accès via Internet Azure
#                 prod        (Premium)  → PE dans snet-pe, accès privé uniquement
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

resource "azurerm_private_endpoint" "servicebus" {
  count = var.servicebus_sku == "Premium" ? 1 : 0

  name                = "pe-sb-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-sb-${local.prefix}"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-sb-${local.prefix}"
    private_dns_zone_ids = [var.private_dns_zone_servicebus_id]
  }
}
