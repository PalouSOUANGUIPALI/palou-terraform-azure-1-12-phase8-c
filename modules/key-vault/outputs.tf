# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : outputs.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "key_vault_id" {
  description = "ID du Key Vault"
  value       = azurerm_key_vault.main.id
}

output "key_vault_name" {
  description = "Nom du Key Vault"
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "URI du Key Vault — injectée dans le service systemd flask-app via cloud-init"
  value       = azurerm_key_vault.main.vault_uri
}

output "private_endpoint_ip" {
  description = "IP privée du Private Endpoint Key Vault dans snet-pe"
  value       = azurerm_private_endpoint.keyvault.private_service_connection[0].private_ip_address
}

output "secret_servicebus_name" {
  description = "Nom du secret Service Bus dans Key Vault"
  value       = azurerm_key_vault_secret.servicebus.name
}

output "secret_eventhub_name" {
  description = "Nom du secret Event Hub dans Key Vault"
  value       = azurerm_key_vault_secret.eventhub.name
}
