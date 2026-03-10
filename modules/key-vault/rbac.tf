# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : rbac.tf
# Description : Attributions RBAC sur le Key Vault.
#               kv_secrets_officer_tf — Service Principal TFC peut écrire
#                                       les secrets lors de l'apply
#               kv_secrets_user_vm    — Managed Identity VM Flask peut lire
#                                       les secrets au démarrage de Flask
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# Service Principal TFC — Key Vault Secrets Officer
# Permet à TFC d'écrire les secrets lors de l'apply.
# Rôle Secrets Officer = lecture + écriture + suppression des secrets.
resource "azurerm_role_assignment" "kv_secrets_officer_tf" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Managed Identity VM Flask — Key Vault Secrets User
# Permet à Flask de lire les secrets au démarrage via ManagedIdentityCredential.
# Rôle Secrets User = lecture uniquement — principe du moindre privilège.
resource "azurerm_role_assignment" "kv_secrets_user_vm" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.vm_app_identity_principal_id
}
