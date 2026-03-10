# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : diagnostic.tf
# Description : Diagnostic settings du Key Vault vers le Log Analytics
#               Workspace. AuditEvent capture toutes les opérations
#               sur les secrets (lecture, écriture, suppression).
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-kv-${local.prefix}"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
