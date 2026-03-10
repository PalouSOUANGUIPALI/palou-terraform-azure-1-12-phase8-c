# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : monitoring
# Fichier : outputs.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

output "log_analytics_workspace_id" {
  description = "ID du Log Analytics Workspace — passé à tous les modules pour les diagnostic settings"
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Nom du Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.name
}

output "action_group_id" {
  description = "ID de l'Action Group — référencé par les alertes dans environments/<env>/main.tf"
  value       = azurerm_monitor_action_group.main.id
}

output "action_group_name" {
  description = "Nom de l'Action Group"
  value       = azurerm_monitor_action_group.main.name
}
