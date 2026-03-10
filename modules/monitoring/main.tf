# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : monitoring
# Fichier : main.tf
# Description : Log Analytics Workspace et Action Group pour les alertes.
#               Les alertes elles-mêmes sont définies directement dans
#               environments/<env>/main.tf — elles dépendent de ressources
#               de plusieurs modules et ne peuvent pas être centralisées ici
#               sans créer des dépendances circulaires.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

locals {
  prefix = "${var.project_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "monitoring"
    environment = var.environment
    phase       = "8c"
    managed_by  = "terraform"
  })
}

# ==============================================================================
# LOG ANALYTICS WORKSPACE
# Reçoit les diagnostic settings de tous les modules :
#   service-bus  — OperationalLogs, VNetAndIPFilteringLogs, AllMetrics
#   event-hub    — OperationalLogs, ArchiveLogs, AutoScaleLogs, AllMetrics
#   key-vault    — AuditEvent, AzurePolicyEvaluationDetails, AllMetrics
# Retention 30 jours — suffisant pour un environnement d'apprentissage.
# ==============================================================================

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

# ==============================================================================
# ACTION GROUP
# Reçoit les notifications des alertes Azure Monitor.
# Configuré avec un webhook vide par défaut — à remplacer par une
# adresse email ou un endpoint Slack en production réelle.
# Les alertes référencent cet Action Group via son ID.
# ==============================================================================

resource "azurerm_monitor_action_group" "main" {
  name                = "ag-${local.prefix}"
  resource_group_name = var.resource_group_name
  short_name          = "ag${var.environment}"
  tags                = local.common_tags
}
