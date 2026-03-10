# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
# Fichier : diagnostic.tf
# Description : Diagnostic settings du Service Bus Namespace vers
#               le Log Analytics Workspace.
#               Catégories de logs : OperationalLogs, VNetAndIPFilteringLogs
#               Métriques : AllMetrics
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

resource "azurerm_monitor_diagnostic_setting" "servicebus" {
  name                       = "diag-sb-${local.prefix}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "VNetAndIPFilteringLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
