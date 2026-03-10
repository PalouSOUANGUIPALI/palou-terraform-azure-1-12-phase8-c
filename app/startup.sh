#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Fichier : startup.sh
# Description : Script de démarrage de l'application Flask.
#               Vérifie les variables d'environnement requises,
#               contrôle la présence du venv Python, effectue une
#               vérification DNS du Key Vault, puis lance Gunicorn.
#               Exécuté par le service systemd flask-app.service
#               configuré dans cloud-init-app.tftpl.
#
#               Variables requises (injectées par systemd via cloud-init) :
#                 KEY_VAULT_URL : URI du Key Vault contenant les secrets
#                                 (ex: https://phase8c-dev-kv.vault.azure.net/)
#                 APP_ENV       : environnement (dev, staging, prod)
#
#               Les connection strings Service Bus et Event Hub ne sont PAS
#               des variables d'environnement — ils sont lus depuis Key Vault
#               par main.py au démarrage via Managed Identity.
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

set -e

echo "===================================================================="
echo "Phase 8C - Démarrage de l'application Flask"
echo "===================================================================="
echo "Environnement  : ${APP_ENV:-non défini}"
echo "Key Vault URL  : ${KEY_VAULT_URL:-non défini}"
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
# Vérification DNS du Key Vault
# Le Key Vault est accessible via Private Endpoint — sa résolution DNS doit
# retourner une IP privée dans snet-pe (10.x.2.x) et non une IP publique.
# Une résolution vers une IP publique indique un problème de VNet link
# sur la zone DNS privée privatelink.vaultcore.azure.net.
# ------------------------------------------------------------------------------

KV_HOSTNAME=$(echo "$KEY_VAULT_URL" | sed 's|https://||' | sed 's|/||')

echo "Vérification DNS Key Vault : ${KV_HOSTNAME}"
if ! host "${KV_HOSTNAME}" > /dev/null 2>&1; then
    echo "AVERTISSEMENT : résolution DNS Key Vault échouée pour ${KV_HOSTNAME}"
    echo "Vérifier que le VNet link de privatelink.vaultcore.azure.net est configuré"
    echo "Démarrage quand même — l'initialisation dans main.py échouera si le DNS est absent"
fi

# ------------------------------------------------------------------------------
# Démarrage Gunicorn
# --workers 2      : 2 workers suffisants pour les phases d'apprentissage
# --timeout 120    : délai étendu pour l'init Key Vault au démarrage
# --access-logfile : logs d'accès vers stdout (capturés par journald)
# --error-logfile  : logs d'erreur vers stdout (capturés par journald)
# ------------------------------------------------------------------------------

PORT="${PORT:-5000}"
WORKERS="${GUNICORN_WORKERS:-2}"
APP_DIR="/opt/flask-app"

echo "Démarrage Gunicorn — port=${PORT} workers=${WORKERS}"

cd "${APP_DIR}"

exec "${VENV_PATH}/bin/gunicorn" \
    --bind "0.0.0.0:${PORT}" \
    --workers "${WORKERS}" \
    --timeout 120 \
    --access-logfile - \
    --error-logfile - \
    --log-level info \
    main:app
