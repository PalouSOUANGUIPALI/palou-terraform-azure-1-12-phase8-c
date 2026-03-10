# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : event-hub
# Fichier : main.tf
# Description : Event Hub Namespace Standard avec 2 TU (dev/staging)
#               ou 4 TU (prod). Le namespace héberge l'Event Hub app-metrics
#               défini dans eventhub.tf.
#               Private Endpoint dans private-endpoint.tf.
#               Diagnostic settings dans diagnostic.tf.
#
#               Event Hub et Service Bus partagent la même zone DNS privée
#               privatelink.servicebus.windows.net — les deux services
#               utilisent le même suffixe DNS Azure.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

locals {
  prefix = "${var.project_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "event-hub"
    environment = var.environment
    phase       = "8c"
    managed_by  = "terraform"
  })
}

resource "azurerm_eventhub_namespace" "main" {
  name                = "evhns-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  capacity            = var.eventhub_capacity

  # Accès public désactivé — accès exclusivement via Private Endpoint
  public_network_access_enabled = false

  # Minimum TLS 1.2
  minimum_tls_version = "1.2"

  # Note : local_auth_enabled n'existe pas sur azurerm_eventhub_namespace
  # en azurerm 3.x — l'authentification par SAS reste disponible mais
  # le SDK azure-eventhub utilise DefaultAzureCredential (Managed Identity)
  # quand aucune SAS key n'est fournie explicitement.

  tags = local.common_tags
}
