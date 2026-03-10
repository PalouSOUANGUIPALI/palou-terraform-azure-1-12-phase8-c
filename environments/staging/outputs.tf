# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : staging
# Fichier : outputs.tf
# Description : Outputs de l'environnement staging.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "resource_group_name" {
  description = "Nom du resource group staging"
  value       = module.networking.resource_group_name
}

output "vnet_name" {
  description = "Nom du VNet staging"
  value       = module.networking.vnet_name
}

output "vm_app_name" {
  description = "Nom de la VM Flask"
  value       = module.compute.vm_app_name
}

output "vm_app_private_ip" {
  description = "IP privée de la VM Flask dans snet-app"
  value       = module.compute.vm_app_private_ip
}

output "vm_app_identity_principal_id" {
  description = "Principal ID de la Managed Identity de la VM Flask"
  value       = module.compute.vm_app_identity_principal_id
}

output "vm_monitoring_name" {
  description = "Nom de la VM Monitoring"
  value       = module.compute.vm_monitoring_name
}

output "vm_monitoring_private_ip" {
  description = "IP privée de la VM Monitoring dans snet-monitoring"
  value       = module.compute.vm_monitoring_private_ip
}

output "servicebus_namespace_name" {
  description = "Nom du Service Bus Namespace"
  value       = module.service_bus.namespace_name
}

output "servicebus_namespace_fqdn" {
  description = "FQDN du Service Bus Namespace"
  value       = module.service_bus.namespace_fqdn
}

output "eventhub_namespace_name" {
  description = "Nom du Event Hub Namespace"
  value       = module.event_hub.namespace_name
}

output "eventhub_namespace_fqdn" {
  description = "FQDN du Event Hub Namespace"
  value       = module.event_hub.namespace_fqdn
}

output "key_vault_name" {
  description = "Nom du Key Vault"
  value       = module.key_vault.key_vault_name
}

output "key_vault_uri" {
  description = "URI du Key Vault"
  value       = module.key_vault.key_vault_uri
}

output "log_analytics_workspace_name" {
  description = "Nom du Log Analytics Workspace"
  value       = module.monitoring.log_analytics_workspace_name
}
