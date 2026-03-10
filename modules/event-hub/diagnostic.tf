# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : event-hub
# Fichier : diagnostic.tf
# Description : Diagnostic settings du Event Hub Namespace vers
#               le Log Analytics Workspace.
#               Catégories de logs : OperationalLogs, ArchiveLogs,
#               AutoScaleLogs, KafkaCoordinatorLogs
#               Métriques : AllMetrics
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

resource "azurerm_monitor_diagnostic_setting" "eventhub" {
  name                       = "diag-evh-${local.prefix}"
  target_resource_id         = azurerm_eventhub_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "ArchiveLogs"
  }

  enabled_log {
    category = "AutoScaleLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
