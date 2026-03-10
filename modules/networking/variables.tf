# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : networking
# Fichier : outputs.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "resource_group_name" {
  description = "Nom du Resource Group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_location" {
  description = "Région du Resource Group"
  value       = azurerm_resource_group.main.location
}

output "vnet_id" {
  description = "ID du Virtual Network"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Nom du Virtual Network"
  value       = azurerm_virtual_network.main.name
}

output "subnet_bastion_id" {
  description = "ID du subnet AzureBastionSubnet"
  value       = azurerm_subnet.bastion.id
}

output "subnet_app_id" {
  description = "ID du subnet snet-app"
  value       = azurerm_subnet.app.id
}

output "subnet_app_prefix" {
  description = "CIDR du subnet snet-app — utilisé dans les règles NSG"
  value       = var.subnet_app_prefix
}

output "subnet_monitoring_id" {
  description = "ID du subnet snet-monitoring"
  value       = azurerm_subnet.monitoring.id
}

output "subnet_monitoring_prefix" {
  description = "CIDR du subnet snet-monitoring — utilisé dans les règles NSG"
  value       = var.subnet_monitoring_prefix
}

output "subnet_pe_id" {
  description = "ID du subnet snet-pe"
  value       = azurerm_subnet.pe.id
}

output "subnet_pe_prefix" {
  description = "CIDR du subnet snet-pe — utilisé dans les règles NSG"
  value       = var.subnet_pe_prefix
}

output "subnet_bastion_prefix" {
  description = "CIDR du subnet AzureBastionSubnet — utilisé dans les règles NSG"
  value       = var.subnet_bastion_prefix
}

output "private_dns_zone_servicebus_id" {
  description = "ID de la zone DNS privatelink.servicebus.windows.net (Service Bus + Event Hub)"
  value       = azurerm_private_dns_zone.servicebus.id
}

output "private_dns_zone_servicebus_name" {
  description = "Nom de la zone DNS Service Bus / Event Hub"
  value       = azurerm_private_dns_zone.servicebus.name
}

output "private_dns_zone_keyvault_id" {
  description = "ID de la zone DNS privatelink.vaultcore.azure.net"
  value       = azurerm_private_dns_zone.keyvault.id
}

output "private_dns_zone_keyvault_name" {
  description = "Nom de la zone DNS Key Vault"
  value       = azurerm_private_dns_zone.keyvault.name
}

output "log_analytics_workspace_id" {
  description = "ID du Log Analytics Workspace — passé aux modules pour les diagnostic settings"
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Nom du Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.name
}
