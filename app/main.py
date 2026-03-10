# ==============================================================================
# Phase 8C - Messaging et Integration
# Fichier : main.py
# Description : Application Flask démontrant Service Bus (queues + topics)
#               et Event Hub (émission de métriques).
#               Les connection strings sont lus depuis Azure Key Vault
#               via la Managed Identity de la VM — zéro secret en clair.
#
# Flux d'authentification :
#   VM Flask (MI) → IMDS (169.254.169.254) → token AAD
#   token AAD → Key Vault (resource: vault.azure.net) → connection strings
#   connection string Service Bus → ServiceBusClient
#   connection string Event Hub   → EventHubProducerClient
#
# Endpoints :
#   GET  /health                          : vérification santé + connectivité
#   POST /api/messages/send               : envoie un message dans queue orders
#   GET  /api/messages/receive            : reçoit un message depuis queue orders
#   GET  /api/messages/dlq                : inspecte la Dead-Letter Queue
#   POST /api/messages/dlq/reprocess      : retraite un message depuis la DLQ
#   POST /api/events/publish              : publie un event sur le topic events
#   GET  /api/events/subscribe/<sub>      : reçoit un event depuis sub-logs ou sub-alerts
#   POST /api/metrics/emit                : envoie une métrique vers Event Hub
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

import os
import json
import uuid
import logging
from datetime import datetime, timezone

from flask import Flask, jsonify, request
from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.eventhub import EventHubProducerClient, EventData

# ------------------------------------------------------------------------------
# Configuration du logging
# ------------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s"
)
logger = logging.getLogger(__name__)

# ------------------------------------------------------------------------------
# Configuration Flask
# ------------------------------------------------------------------------------

app = Flask(__name__)

# ------------------------------------------------------------------------------
# Variables d'environnement
# Injectées par le service systemd via cloud-init-app.tftpl.
# KEY_VAULT_URL est la seule variable requise — les connection strings
# sont lus depuis Key Vault et jamais exposés dans l'environnement.
# ------------------------------------------------------------------------------

KEY_VAULT_URL = os.getenv("KEY_VAULT_URL", "")
APP_ENV       = os.getenv("APP_ENV", "dev")

# ------------------------------------------------------------------------------
# Constantes Service Bus
# ------------------------------------------------------------------------------

SERVICEBUS_QUEUE_ORDERS = "orders"
SERVICEBUS_TOPIC_EVENTS = "events"
SERVICEBUS_MAX_MESSAGES = 1


# ==============================================================================
# AUTHENTIFICATION — MANAGED IDENTITY + KEY VAULT
# ==============================================================================

def get_secret(secret_name: str) -> str:
    """
    Lit un secret depuis Azure Key Vault via la Managed Identity de la VM.

    ManagedIdentityCredential contacte l'IMDS (169.254.169.254) pour obtenir
    un token JWT AAD — aucun credential explicite requis.
    L'IMDS est accessible sans règle NSG (adresse link-local Azure).
    """
    if not KEY_VAULT_URL:
        raise ValueError("Variable d'environnement KEY_VAULT_URL non définie")
    credential = ManagedIdentityCredential()
    client = SecretClient(vault_url=KEY_VAULT_URL, credential=credential)
    secret = client.get_secret(secret_name)
    logger.debug("Secret '%s' lu depuis Key Vault", secret_name)
    return secret.value


# ==============================================================================
# INITIALISATION DES CLIENTS
# Appelée au niveau module — s'exécute au démarrage des workers gunicorn.
# Ne pas déplacer dans if __name__ == "__main__" : gunicorn n'exécuterait
# pas ce bloc et les clients seraient None au moment des requêtes.
# ==============================================================================

def init_clients():
    """
    Initialise les clients Service Bus et Event Hub en lisant les connection
    strings depuis Key Vault via Managed Identity.
    Retourne le tuple (servicebus_conn_str, eventhub_conn_str).
    """
    logger.info("Initialisation des clients via Key Vault : %s", KEY_VAULT_URL)

    servicebus_conn = get_secret("servicebus-connection-string")
    eventhub_conn   = get_secret("eventhub-connection-string")

    logger.info("Connection strings lus depuis Key Vault")
    return servicebus_conn, eventhub_conn


# Initialisation au niveau module
servicebus_conn_str, eventhub_conn_str = init_clients()


# ==============================================================================
# HELPERS SERVICE BUS
# ==============================================================================

def get_servicebus_client():
    """Retourne un ServiceBusClient à partir de la connection string."""
    return ServiceBusClient.from_connection_string(servicebus_conn_str)


def get_eventhub_producer():
    """Retourne un EventHubProducerClient à partir de la connection string."""
    return EventHubProducerClient.from_connection_string(
        eventhub_conn_str,
        eventhub_name="app-metrics"
    )


# ==============================================================================
# ENDPOINTS — SANTÉ
# ==============================================================================

@app.route("/health")
def health():
    """
    Vérifie la santé de l'application et la connectivité à Service Bus
    et Event Hub.
    Retourne 200 si tout est opérationnel, 503 si un service est inaccessible.
    """
    status = {
        "service":     "flask-phase8c",
        "environment": APP_ENV,
        "services": {
            "service_bus": {"status": "unknown"},
            "event_hub":   {"status": "unknown"}
        }
    }
    http_code = 200

    # Vérification Service Bus — ouverture d'une connexion sans opération
    try:
        with get_servicebus_client() as client:
            # La création du receiver suffit à tester la connectivité
            with client.get_queue_receiver(
                queue_name=SERVICEBUS_QUEUE_ORDERS,
                max_wait_time=2
            ):
                pass
        status["services"]["service_bus"] = {"status": "healthy"}
        logger.info("Health check Service Bus : OK")
    except Exception as e:
        status["services"]["service_bus"] = {"status": "unhealthy", "error": str(e)}
        logger.error("Health check Service Bus : ECHEC — %s", str(e))
        http_code = 503

    # Vérification Event Hub — ouverture d'un producer sans envoi
    try:
        with get_eventhub_producer() as producer:
            _ = producer.get_eventhub_properties()
        status["services"]["event_hub"] = {"status": "healthy"}
        logger.info("Health check Event Hub : OK")
    except Exception as e:
        status["services"]["event_hub"] = {"status": "unhealthy", "error": str(e)}
        logger.error("Health check Event Hub : ECHEC — %s", str(e))
        http_code = 503

    status["status"] = "healthy" if http_code == 200 else "degraded"
    return jsonify(status), http_code


# ==============================================================================
# ENDPOINTS — QUEUE ORDERS
# ==============================================================================

@app.route("/api/messages/send", methods=["POST"])
def send_message():
    """
    Envoie un message dans la queue orders.
    Corps requis : { "order_id": string?, "product": string, "quantity": number }
    Un order_id est généré automatiquement si absent.
    """
    data = request.get_json(silent=True) or {}
    if not data.get("product"):
        return jsonify({"error": "product est requis"}), 400

    message_body = {
        "order_id":   data.get("order_id", str(uuid.uuid4())),
        "product":    data["product"],
        "quantity":   data.get("quantity", 1),
        "sent_at":    datetime.now(timezone.utc).isoformat(),
        "environment": APP_ENV
    }

    try:
        with get_servicebus_client() as client:
            with client.get_queue_sender(queue_name=SERVICEBUS_QUEUE_ORDERS) as sender:
                msg = ServiceBusMessage(
                    json.dumps(message_body),
                    content_type="application/json"
                )
                sender.send_messages(msg)

        logger.info("Message envoyé queue orders : order_id=%s", message_body["order_id"])
        return jsonify({"sent": True, "message": message_body}), 201

    except Exception as e:
        logger.error("Erreur envoi message Service Bus : %s", str(e))
        return jsonify({"error": str(e)}), 500


@app.route("/api/messages/receive", methods=["GET"])
def receive_message():
    """
    Reçoit et acquitte un message depuis la queue orders.
    Utilise receive_mode=PEEK_LOCK — le message est verrouillé pendant
    le traitement puis supprimé après complete_message().
    Si le traitement échoue, le message est libéré et redevient visible.
    Retourne 204 si la queue est vide.
    """
    try:
        with get_servicebus_client() as client:
            with client.get_queue_receiver(
                queue_name=SERVICEBUS_QUEUE_ORDERS,
                max_wait_time=3
            ) as receiver:
                messages = receiver.receive_messages(
                    max_message_count=SERVICEBUS_MAX_MESSAGES,
                    max_wait_time=3
                )
                if not messages:
                    return jsonify({"message": None, "queue_empty": True}), 204

                msg = messages[0]
                body = json.loads(str(msg))
                receiver.complete_message(msg)

                logger.info(
                    "Message reçu et acquitté queue orders : order_id=%s",
                    body.get("order_id")
                )
                return jsonify({
                    "message":           body,
                    "delivery_count":    msg.delivery_count,
                    "enqueued_time_utc": str(msg.enqueued_time_utc)
                })

    except Exception as e:
        logger.error("Erreur réception message Service Bus : %s", str(e))
        return jsonify({"error": str(e)}), 500


@app.route("/api/messages/dlq", methods=["GET"])
def inspect_dlq():
    """
    Inspecte les messages dans la Dead-Letter Queue de orders.
    Utilise PEEK uniquement — les messages restent dans la DLQ.
    La DLQ contient les messages qui ont dépassé max_delivery_count
    ou dont le TTL a expiré avec dead_lettering_on_message_expiration=true.
    """
    try:
        with get_servicebus_client() as client:
            with client.get_queue_receiver(
                queue_name=SERVICEBUS_QUEUE_ORDERS,
                sub_queue="deadletter",
                max_wait_time=3
            ) as receiver:
                messages = receiver.peek_messages(max_message_count=10)
                result = []
                for msg in messages:
                    result.append({
                        "body":               json.loads(str(msg)),
                        "delivery_count":     msg.delivery_count,
                        "dead_letter_reason": msg.dead_letter_reason,
                        "enqueued_time_utc":  str(msg.enqueued_time_utc)
                    })

        logger.info("Inspection DLQ : %d messages", len(result))
        return jsonify({"dlq_messages": result, "count": len(result)})

    except Exception as e:
        logger.error("Erreur inspection DLQ : %s", str(e))
        return jsonify({"error": str(e)}), 500


@app.route("/api/messages/dlq/reprocess", methods=["POST"])
def reprocess_dlq():
    """
    Retraite un message de la DLQ en le réenqueuing dans orders.
    Reçoit le message de la DLQ, le complète (supprime de la DLQ),
    puis l'envoie de nouveau dans la queue principale.
    Retourne 204 si la DLQ est vide.
    """
    try:
        with get_servicebus_client() as client:
            with client.get_queue_receiver(
                queue_name=SERVICEBUS_QUEUE_ORDERS,
                sub_queue="deadletter",
                max_wait_time=3
            ) as receiver:
                messages = receiver.receive_messages(
                    max_message_count=SERVICEBUS_MAX_MESSAGES,
                    max_wait_time=3
                )
                if not messages:
                    return jsonify({"reprocessed": False, "dlq_empty": True}), 204

                msg = messages[0]
                body = json.loads(str(msg))
                receiver.complete_message(msg)

            # Réenqueue dans la queue principale
            with client.get_queue_sender(queue_name=SERVICEBUS_QUEUE_ORDERS) as sender:
                requeued = ServiceBusMessage(
                    json.dumps(body),
                    content_type="application/json"
                )
                sender.send_messages(requeued)

        logger.info(
            "Message DLQ retraité : order_id=%s", body.get("order_id")
        )
        return jsonify({"reprocessed": True, "message": body})

    except Exception as e:
        logger.error("Erreur retraitement DLQ : %s", str(e))
        return jsonify({"error": str(e)}), 500


# ==============================================================================
# ENDPOINTS — TOPIC EVENTS
# ==============================================================================

@app.route("/api/events/publish", methods=["POST"])
def publish_event():
    """
    Publie un event sur le topic events.
    Corps requis : { "type": string, "level": string, "payload": object? }
    La propriété level est envoyée comme application property du message
    (pas dans le body) — nécessaire pour le filtre SQL de sub-alerts
    qui évalue les properties, pas le body JSON.
    """
    data = request.get_json(silent=True) or {}
    if not data.get("type") or not data.get("level"):
        return jsonify({"error": "type et level sont requis"}), 400

    event_body = {
        "event_id":    str(uuid.uuid4()),
        "type":        data["type"],
        "level":       data["level"],
        "payload":     data.get("payload", {}),
        "published_at": datetime.now(timezone.utc).isoformat(),
        "environment":  APP_ENV
    }

    try:
        with get_servicebus_client() as client:
            with client.get_topic_sender(topic_name=SERVICEBUS_TOPIC_EVENTS) as sender:
                msg = ServiceBusMessage(
                    json.dumps(event_body),
                    content_type="application/json",
                    # application_properties — évalué par le filtre SQL de sub-alerts
                    # level doit être ici et non seulement dans le body JSON
                    application_properties={"level": data["level"]}
                )
                sender.send_messages(msg)

        logger.info(
            "Event publié topic events : type=%s level=%s event_id=%s",
            data["type"], data["level"], event_body["event_id"]
        )
        return jsonify({"published": True, "event": event_body}), 201

    except Exception as e:
        logger.error("Erreur publication event : %s", str(e))
        return jsonify({"error": str(e)}), 500


@app.route("/api/events/subscribe/<subscription>", methods=["GET"])
def receive_event(subscription):
    """
    Reçoit un event depuis la subscription spécifiée du topic events.
    Subscriptions valides : sub-logs, sub-alerts.
    sub-logs    — reçoit tous les events sans filtre.
    sub-alerts  — reçoit uniquement les events avec level=critical.
    Retourne 204 si la subscription est vide.
    """
    valid_subscriptions = ["sub-logs", "sub-alerts"]
    if subscription not in valid_subscriptions:
        return jsonify({
            "error": f"Subscription invalide. Valeurs acceptées : {valid_subscriptions}"
        }), 400

    try:
        with get_servicebus_client() as client:
            with client.get_subscription_receiver(
                topic_name=SERVICEBUS_TOPIC_EVENTS,
                subscription_name=subscription,
                max_wait_time=3
            ) as receiver:
                messages = receiver.receive_messages(
                    max_message_count=SERVICEBUS_MAX_MESSAGES,
                    max_wait_time=3
                )
                if not messages:
                    return jsonify({"event": None, "subscription_empty": True}), 204

                msg = messages[0]
                body = json.loads(str(msg))
                receiver.complete_message(msg)

                logger.info(
                    "Event reçu subscription=%s event_id=%s",
                    subscription, body.get("event_id")
                )
                return jsonify({
                    "event":              body,
                    "subscription":       subscription,
                    "delivery_count":     msg.delivery_count,
                    "enqueued_time_utc":  str(msg.enqueued_time_utc)
                })

    except Exception as e:
        logger.error("Erreur réception event subscription=%s : %s", subscription, str(e))
        return jsonify({"error": str(e)}), 500


# ==============================================================================
# ENDPOINTS — EVENT HUB MÉTRIQUES
# ==============================================================================

@app.route("/api/metrics/emit", methods=["POST"])
def emit_metric():
    """
    Envoie une métrique vers l'Event Hub app-metrics.
    Corps requis : { "name": string, "value": number, "labels": object? }
    Le consumer.py lit cet event depuis le consumer group grafana
    et le pousse vers Pushgateway (snet-monitoring:9091).
    """
    data = request.get_json(silent=True) or {}
    if not data.get("name") or data.get("value") is None:
        return jsonify({"error": "name et value sont requis"}), 400

    metric = {
        "metric_id":  str(uuid.uuid4()),
        "name":       data["name"],
        "value":      float(data["value"]),
        "labels":     data.get("labels", {}),
        "emitted_at": datetime.now(timezone.utc).isoformat(),
        "environment": APP_ENV
    }

    try:
        with get_eventhub_producer() as producer:
            batch = producer.create_batch()
            batch.add(EventData(json.dumps(metric)))
            producer.send_batch(batch)

        logger.info(
            "Métrique émise vers Event Hub : name=%s value=%s",
            metric["name"], metric["value"]
        )
        return jsonify({"emitted": True, "metric": metric}), 201

    except Exception as e:
        logger.error("Erreur émission métrique Event Hub : %s", str(e))
        return jsonify({"error": str(e)}), 500


# ==============================================================================
# POINT D'ENTRÉE
# Gunicorn charge ce module directement — init_clients() est déjà appelé
# au niveau module ci-dessus. Ce bloc ne sert que pour les tests locaux.
# ==============================================================================

if __name__ == "__main__":
    logger.info("Démarrage Phase 8C — env=%s", APP_ENV)
    logger.info("Key Vault URL : %s", KEY_VAULT_URL)
    port = int(os.getenv("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=False)
