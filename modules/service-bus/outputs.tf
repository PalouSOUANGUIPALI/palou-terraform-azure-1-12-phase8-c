# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
# Fichier : outputs.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "namespace_id" {
  description = "ID du Service Bus Namespace"
  value       = azurerm_servicebus_namespace.main.id
}

output "namespace_name" {
  description = "Nom du Service Bus Namespace"
  value       = azurerm_servicebus_namespace.main.name
}

output "namespace_fqdn" {
  description = "FQDN du Service Bus Namespace — utilisé pour la connexion via Private Endpoint"
  value       = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

output "queue_orders_id" {
  description = "ID de la queue orders"
  value       = azurerm_servicebus_queue.orders.id
}

output "topic_events_id" {
  description = "ID du topic events"
  value       = azurerm_servicebus_topic.events.id
}

output "subscription_sub_logs_id" {
  description = "ID de la subscription sub-logs"
  value       = azurerm_servicebus_subscription.sub_logs.id
}

output "subscription_sub_alerts_id" {
  description = "ID de la subscription sub-alerts"
  value       = azurerm_servicebus_subscription.sub_alerts.id
}

output "private_endpoint_ip" {
  description = "IP privée du Private Endpoint Service Bus dans snet-pe"
  value       = azurerm_private_endpoint.servicebus.private_service_connection[0].private_ip_address
}
