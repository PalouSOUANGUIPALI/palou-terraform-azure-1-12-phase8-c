# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : compute
# Fichier : outputs.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "vm_app_id" {
  description = "ID de la VM Flask"
  value       = azurerm_linux_virtual_machine.app.id
}

output "vm_app_name" {
  description = "Nom de la VM Flask"
  value       = azurerm_linux_virtual_machine.app.name
}

output "vm_app_private_ip" {
  description = "IP privée de la VM Flask"
  value       = azurerm_network_interface.app.private_ip_address
}

output "vm_app_identity_principal_id" {
  description = "Principal ID de la Managed Identity de la VM Flask — utilisé pour les attributions RBAC"
  value       = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

output "vm_monitoring_id" {
  description = "ID de la VM Monitoring"
  value       = azurerm_linux_virtual_machine.monitoring.id
}

output "vm_monitoring_name" {
  description = "Nom de la VM Monitoring"
  value       = azurerm_linux_virtual_machine.monitoring.name
}

output "vm_monitoring_private_ip" {
  description = "IP privée de la VM Monitoring — utilisée par le consumer pour joindre Pushgateway"
  value       = azurerm_network_interface.monitoring.private_ip_address
}
