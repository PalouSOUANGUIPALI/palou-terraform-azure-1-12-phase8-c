# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : event-hub
# Fichier : outputs.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "namespace_id" {
  description = "ID du Event Hub Namespace"
  value       = azurerm_eventhub_namespace.main.id
}

output "namespace_name" {
  description = "Nom du Event Hub Namespace"
  value       = azurerm_eventhub_namespace.main.name
}

output "namespace_fqdn" {
  description = "FQDN du Event Hub Namespace — utilisé pour la connexion via Private Endpoint"
  value       = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
}

output "eventhub_name" {
  description = "Nom de l'Event Hub app-metrics"
  value       = azurerm_eventhub.app_metrics.name
}

output "eventhub_id" {
  description = "ID de l'Event Hub app-metrics"
  value       = azurerm_eventhub.app_metrics.id
}

output "consumer_group_grafana_name" {
  description = "Nom du consumer group grafana — utilisé par consumer.py"
  value       = azurerm_eventhub_consumer_group.grafana.name
}

output "private_endpoint_ip" {
  description = "IP privée du Private Endpoint Event Hub dans snet-pe"
  value       = azurerm_private_endpoint.eventhub.private_service_connection[0].private_ip_address
}

output "connection_string" {
  description = "Connection string primaire du Event Hub Namespace — transmis au module key-vault pour stockage dans Key Vault"
  value       = azurerm_eventhub_namespace.main.default_primary_connection_string
  sensitive   = true
}
