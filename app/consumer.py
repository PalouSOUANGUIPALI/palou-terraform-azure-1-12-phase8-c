# ==============================================================================
# Phase 8C - Messaging et Integration
# Fichier : consumer.py
# Description : Consumer Event Hub — lit les métriques depuis le consumer
#               group grafana et les pousse vers Pushgateway.
#               Tourne en tant que service systemd eventhub-consumer.service
#               sur la VM Flask (snet-app).
#
# Flux :
#   Event Hub app-metrics (PE) → EventHubConsumerClient (consumer group: grafana)
#   → parse métrique JSON → HTTP POST Pushgateway :9091
#   Prometheus scrape Pushgateway :9090 → Grafana dashboard métriques custom
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

import os
import json
import logging
import time
import urllib.request
import urllib.error

from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from azure.eventhub import EventHubConsumerClient

# ------------------------------------------------------------------------------
# Configuration du logging
# ------------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s"
)
logger = logging.getLogger(__name__)

# ------------------------------------------------------------------------------
# Variables d'environnement
# ------------------------------------------------------------------------------

KEY_VAULT_URL    = os.getenv("KEY_VAULT_URL", "")
APP_ENV          = os.getenv("APP_ENV", "dev")

# IP de la VM Monitoring dans snet-monitoring — Pushgateway écoute sur :9091
# La VM Monitoring est dans le même VNet — accessible par IP privée directement.
PUSHGATEWAY_URL  = os.getenv("PUSHGATEWAY_URL", "http://10.0.4.4:9091")

EVENTHUB_NAME         = "app-metrics"
CONSUMER_GROUP        = "grafana"
PUSHGATEWAY_JOB       = "flask_app_metrics"


# ==============================================================================
# AUTHENTIFICATION — MANAGED IDENTITY + KEY VAULT
# ==============================================================================

def get_secret(secret_name: str) -> str:
    """Lit un secret depuis Key Vault via Managed Identity."""
    if not KEY_VAULT_URL:
        raise ValueError("Variable d'environnement KEY_VAULT_URL non définie")
    credential = ManagedIdentityCredential()
    client = SecretClient(vault_url=KEY_VAULT_URL, credential=credential)
    return client.get_secret(secret_name).value


# ==============================================================================
# PUSHGATEWAY
# ==============================================================================

def push_metric_to_gateway(name: str, value: float, labels: dict, environment: str):
    """
    Envoie une métrique vers Pushgateway au format texte Prometheus.
    Format URL : /metrics/job/<job>/label1/value1/label2/value2
    Format body : # TYPE <name> gauge\n<name>{labels} <value>\n

    Pushgateway conserve la dernière valeur reçue par job/labels.
    Prometheus scrape Pushgateway toutes les 15s et expose les métriques
    à Grafana via la datasource Prometheus.
    """
    # Construction de l'URL avec les labels comme segments de chemin
    label_path = f"environment/{environment}"
    for k, v in labels.items():
        label_path += f"/{k}/{v}"

    url = f"{PUSHGATEWAY_URL}/metrics/job/{PUSHGATEWAY_JOB}/{label_path}"

    # Corps au format texte Prometheus
    # gauge est le type approprié pour des valeurs instantanées (pas des compteurs)
    safe_name = name.replace("-", "_").replace(".", "_")
    body = f"# TYPE {safe_name} gauge\n{safe_name} {value}\n"

    try:
        req = urllib.request.Request(
            url,
            data=body.encode("utf-8"),
            method="POST",
            headers={"Content-Type": "text/plain"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            logger.debug(
                "Métrique poussée Pushgateway : name=%s value=%s status=%d",
                safe_name, value, resp.status
            )
    except urllib.error.URLError as e:
        logger.error("Erreur push Pushgateway : name=%s — %s", safe_name, str(e))


# ==============================================================================
# CONSUMER EVENT HUB
# ==============================================================================

def on_event(partition_context, event):
    """
    Callback appelé par EventHubConsumerClient pour chaque event reçu.
    Parse le body JSON, extrait les champs name/value/labels,
    pousse vers Pushgateway, puis met à jour le checkpoint.

    Le checkpoint enregistre l'offset lu dans le consumer group grafana —
    permet au consumer de reprendre depuis le bon offset après un redémarrage.
    """
    try:
        body = json.loads(event.body_as_str())
        name   = body.get("name", "unknown_metric")
        value  = float(body.get("value", 0))
        labels = body.get("labels", {})
        env    = body.get("environment", APP_ENV)

        logger.info(
            "Event reçu partition=%s name=%s value=%s",
            partition_context.partition_id, name, value
        )

        push_metric_to_gateway(name, value, labels, env)

        # Mise à jour du checkpoint — évite de retraiter les events
        # déjà consommés après un redémarrage du service
        partition_context.update_checkpoint(event)

    except json.JSONDecodeError as e:
        logger.error("Event non parseable JSON : %s", str(e))
    except Exception as e:
        logger.error("Erreur traitement event : %s", str(e))


def on_error(partition_context, error):
    """Callback appelé en cas d'erreur sur une partition."""
    if partition_context:
        logger.error(
            "Erreur consumer partition=%s : %s",
            partition_context.partition_id, str(error)
        )
    else:
        logger.error("Erreur consumer (pas de partition context) : %s", str(error))


def main():
    """
    Point d'entrée principal du consumer.
    Lit la connection string depuis Key Vault, démarre le client Event Hub
    et consomme en continu depuis toutes les partitions de app-metrics.
    En cas d'erreur de connexion, réessaie après 30 secondes.
    """
    logger.info("Démarrage consumer Event Hub — env=%s", APP_ENV)
    logger.info("Key Vault URL : %s", KEY_VAULT_URL)
    logger.info("Consumer group : %s", CONSUMER_GROUP)
    logger.info("Pushgateway URL : %s", PUSHGATEWAY_URL)

    eventhub_conn = get_secret("eventhub-connection-string")

    while True:
        try:
            logger.info("Connexion à Event Hub app-metrics...")
            client = EventHubConsumerClient.from_connection_string(
                eventhub_conn,
                consumer_group=CONSUMER_GROUP,
                eventhub_name=EVENTHUB_NAME
            )
            with client:
                logger.info("Consumer actif — en attente d'events")
                client.receive(
                    on_event=on_event,
                    on_error=on_error,
                    starting_position="-1"  # début du flux conservé (1 jour)
                )

        except KeyboardInterrupt:
            logger.info("Consumer arrêté par l'utilisateur")
            break
        except Exception as e:
            logger.error("Erreur connexion Event Hub : %s — retry dans 30s", str(e))
            time.sleep(30)


if __name__ == "__main__":
    main()
