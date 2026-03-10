# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : event-hub
# Fichier : private-endpoint.tf
# Description : Private Endpoint pour le Event Hub Namespace.
#               Utilise la zone DNS privatelink.servicebus.windows.net
#               partagée avec Service Bus — les deux services utilisent
#               le même suffixe DNS Azure et la même zone privée.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

resource "azurerm_private_endpoint" "eventhub" {
  name                = "pe-evh-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_pe_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-evh-${local.prefix}"
    private_connection_resource_id = azurerm_eventhub_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-evh-${local.prefix}"
    private_dns_zone_ids = [var.private_dns_zone_servicebus_id]
  }
}
