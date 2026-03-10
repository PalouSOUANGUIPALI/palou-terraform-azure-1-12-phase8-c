# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
# Fichier : queues.tf
# Description : Queue orders avec Dead-Letter Queue.
#               La DLQ est créée automatiquement par Azure Service Bus —
#               elle n'a pas de ressource Terraform dédiée.
#               Les messages non traités après max_delivery_count tentatives
#               sont automatiquement transférés dans la DLQ.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# QUEUE — orders
# Reçoit les commandes envoyées par POST /api/messages/send.
# Le consumer lit les messages via GET /api/messages/receive.
# Les messages non acquittés après max_delivery_count tentatives
# sont transférés automatiquement dans la Dead-Letter Queue (DLQ).
#
# dead_lettering_on_message_expiration = true : les messages expirés
# (TTL dépassé) vont aussi en DLQ plutôt que d'être supprimés silencieusement.
# Cela permet l'inspection et le retraitement via /api/messages/dlq.
# ==============================================================================

resource "azurerm_servicebus_queue" "orders" {
  name         = "orders"
  namespace_id = azurerm_servicebus_namespace.main.id

  # Durée de vie maximale d'un message dans la queue — 7 jours
  # Un message non consommé dans ce délai est transféré en DLQ
  default_message_ttl = "P7D"

  # Nombre maximum de tentatives de livraison avant transfert en DLQ.
  # Après 10 tentatives échouées, le message est considéré poison
  # et déplacé automatiquement dans orders/$DeadLetterQueue.
  max_delivery_count = 10

  # Les messages expirés (TTL) vont en DLQ plutôt que d'être supprimés
  dead_lettering_on_message_expiration = true

  # Durée du lock lors de la réception — 60 secondes pour traiter le message.
  # Si le consumer ne complète pas dans ce délai, le message redevient visible.
  lock_duration = "PT1M"

  # Taille maximale de la queue en MB
  max_size_in_megabytes = 1024
}
