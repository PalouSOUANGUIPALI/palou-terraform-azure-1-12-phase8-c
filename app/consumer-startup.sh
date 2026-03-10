#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Fichier : consumer-startup.sh
# Description : Script de démarrage du consumer Event Hub.
#               Vérifie les variables d'environnement requises,
#               contrôle la présence du venv Python, vérifie la
#               disponibilité de Pushgateway, puis lance consumer.py.
#               Exécuté par le service systemd eventhub-consumer.service
#               configuré dans cloud-init-app.tftpl.
#
#               Variables requises (injectées par systemd via cloud-init) :
#                 KEY_VAULT_URL   : URI du Key Vault contenant les secrets
#                 APP_ENV         : environnement (dev, staging, prod)
#               Variable optionnelle :
#                 PUSHGATEWAY_URL : URL de Pushgateway (défaut: http://10.0.4.4:9091)
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

set -e

echo "===================================================================="
echo "Phase 8C - Démarrage du consumer Event Hub"
echo "===================================================================="
echo "Environnement    : ${APP_ENV:-non défini}"
echo "Key Vault URL    : ${KEY_VAULT_URL:-non défini}"
echo "Pushgateway URL  : ${PUSHGATEWAY_URL:-http://10.0.4.4:9091}"
echo "===================================================================="

# ------------------------------------------------------------------------------
# Vérification des variables d'environnement requises
# ------------------------------------------------------------------------------

MISSING_VARS=0

for VAR in KEY_VAULT_URL APP_ENV; do
    if [ -z "${!VAR}" ]; then
        echo "ERREUR : variable d'environnement manquante : ${VAR}"
        MISSING_VARS=1
    fi
done

if [ "$MISSING_VARS" -eq 1 ]; then
    echo "Variables d'environnement manquantes — arrêt du démarrage"
    exit 1
fi

# ------------------------------------------------------------------------------
# Vérification de la présence du venv Python
# ------------------------------------------------------------------------------

VENV_PATH="/opt/flask-app/venv"

if [ ! -d "$VENV_PATH" ]; then
    echo "ERREUR : environnement virtuel Python introuvable : ${VENV_PATH}"
    echo "Vérifier que cloud-init s'est bien exécuté jusqu'à la fin"
    exit 1
fi

# ------------------------------------------------------------------------------
# Vérification Pushgateway
# Le consumer pousse les métriques vers Pushgateway sur snet-monitoring.
# Si Pushgateway n'est pas disponible au démarrage, le consumer démarre
# quand même — les erreurs push sont loguées mais ne stoppent pas le consumer.
# ------------------------------------------------------------------------------

PGW_URL="${PUSHGATEWAY_URL:-http://10.0.4.4:9091}"
PGW_HOST=$(echo "$PGW_URL" | sed 's|http://||' | cut -d: -f1)
PGW_PORT=$(echo "$PGW_URL" | sed 's|http://||' | cut -d: -f2)

echo "Vérification Pushgateway : ${PGW_HOST}:${PGW_PORT}"
if ! (echo > /dev/tcp/"${PGW_HOST}"/"${PGW_PORT}") 2>/dev/null; then
    echo "AVERTISSEMENT : Pushgateway inaccessible — ${PGW_URL}"
    echo "La VM Monitoring est peut-être encore en cours de démarrage"
    echo "Démarrage quand même — les métriques seront poussées dès que Pushgateway sera disponible"
fi

# ------------------------------------------------------------------------------
# Démarrage du consumer
# ------------------------------------------------------------------------------

APP_DIR="/opt/flask-app"

echo "Démarrage consumer.py"

cd "${APP_DIR}"

exec "${VENV_PATH}/bin/python3" consumer.py
