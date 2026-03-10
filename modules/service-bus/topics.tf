# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
# Fichier : topics.tf
# Description : Topic events avec deux subscriptions.
#               sub-logs    — reçoit tous les events (logs applicatifs)
#               sub-alerts  — reçoit uniquement les events critiques
#               Le filtrage par subscription permet à plusieurs consommateurs
#               indépendants de lire le même event avec des vues différentes.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# TOPIC — events
# Un topic est un canal de publication — les producteurs publient des events,
# les subscriptions filtrent et livrent à chaque consommateur indépendamment.
# Contrairement à une queue (1 producteur → 1 consommateur), un topic permet
# le pattern publish/subscribe (1 producteur → N consommateurs).
# ==============================================================================

resource "azurerm_servicebus_topic" "events" {
  name         = "events"
  namespace_id = azurerm_servicebus_namespace.main.id

  # Durée de vie des messages dans le topic
  default_message_ttl = "P1D"

  # Taille maximale du topic en MB
  max_size_in_megabytes = 1024
}

# ==============================================================================
# SUBSCRIPTION — sub-logs
# Reçoit tous les events publiés sur le topic events sans filtre.
# Utilisée pour les logs applicatifs — chaque event est conservé.
# ==============================================================================

resource "azurerm_servicebus_subscription" "sub_logs" {
  name               = "sub-logs"
  topic_id           = azurerm_servicebus_topic.events.id
  max_delivery_count = 10

  # Durée du lock — 60 secondes pour traiter chaque event
  lock_duration = "PT1M"

  # Les messages non consommés restent 1 jour
  default_message_ttl = "P1D"

  dead_lettering_on_message_expiration = true
}

# ==============================================================================
# SUBSCRIPTION — sub-alerts
# Reçoit uniquement les events avec la propriété level = "critical".
# Le filtre SQL est évalué sur les propriétés du message — pas sur le body.
# Sans filtre explicite, une subscription reçoit tous les messages (filtre 1=1).
# ==============================================================================

resource "azurerm_servicebus_subscription" "sub_alerts" {
  name                = "sub-alerts"
  topic_id            = azurerm_servicebus_topic.events.id
  max_delivery_count  = 10
  lock_duration       = "PT1M"
  default_message_ttl = "P1D"

  dead_lettering_on_message_expiration = true
}

# Filtre SQL sur sub-alerts — uniquement les events critiques
# La règle par défaut ($Default) est remplacée par ce filtre.
# Le filtre s'applique sur les application properties du message,
# pas sur le body JSON — Flask doit donc envoyer level comme property.
resource "azurerm_servicebus_subscription_rule" "sub_alerts_filter" {
  name            = "filter-critical"
  subscription_id = azurerm_servicebus_subscription.sub_alerts.id
  filter_type     = "SqlFilter"

  # sql_filter est un argument string en azurerm 3.x — pas un bloc imbriqué
  sql_filter = "level = 'critical'"
}

