# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : event-hub
# Fichier : eventhub.tf
# Description : Event Hub app-metrics avec deux consumer groups.
#               $Default   — consumer group système, toujours présent
#               grafana    — consumer group dédié au process consumer.py
#               Chaque consumer group maintient son propre offset de lecture —
#               deux consumers indépendants peuvent lire le même flux
#               sans interférer l'un avec l'autre.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# EVENT HUB — app-metrics
# Reçoit les métriques applicatives émises par POST /api/metrics/emit.
# partition_count = 2 — minimum pour la parallélisation.
#   Chaque partition est un flux ordonné indépendant. Un consumer group
#   peut assigner un consumer par partition pour paralléliser la lecture.
#   2 partitions suffisent pour un usage pédagogique — prod utiliserait 4+.
# message_retention = 1 — les events sont conservés 1 jour.
#   Cela permet au consumer de relire les events en cas de redémarrage.
#
# Note : le provider azurerm ~> 3.0 n'accepte plus namespace_id sur
# azurerm_eventhub — il faut namespace_name + resource_group_name.
# ==============================================================================

resource "azurerm_eventhub" "app_metrics" {
  name                = "app-metrics"
  namespace_name      = azurerm_eventhub_namespace.main.name
  resource_group_name = var.resource_group_name
  partition_count     = var.eventhub_partition_count
  message_retention   = 1
}

# ==============================================================================
# CONSUMER GROUP — grafana
# Utilisé exclusivement par consumer.py (eventhub-consumer.service).
# consumer.py lit les métriques depuis ce consumer group et les pousse
# vers Pushgateway (snet-monitoring:9091).
# Le consumer group $Default est créé automatiquement par Azure —
# pas de ressource Terraform nécessaire pour lui.
# ==============================================================================

resource "azurerm_eventhub_consumer_group" "grafana" {
  name                = "grafana"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.app_metrics.name
  resource_group_name = var.resource_group_name
}
