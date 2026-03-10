#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : destroy-env.sh
# Description : Lance un terraform destroy via l'API TFC pour un
#               environnement spécifique.
#
#               ATTENTION : Action IRREVERSIBLE.
#               Toutes les ressources Azure de l'environnement seront
#               supprimées définitivement, y compris les namespaces
#               Service Bus et Event Hub et leurs données.
#
# Prérequis :
#   - Connexion à TFC (terraform login)
#
# Usage :
#   ./scripts/destroy-env.sh <env>
#   ./scripts/destroy-env.sh dev
#   ./scripts/destroy-env.sh staging
#   ./scripts/destroy-env.sh prod
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage : $0 <env>"
  echo ""
  echo "  env : dev | staging | prod"
  exit 1
fi

ENV="$1"

case "$ENV" in
  dev|staging|prod) ;;
  *)
    echo "ERREUR : Environnement '$ENV' inconnu."
    echo "Valeurs acceptées : dev | staging | prod"
    exit 1
    ;;
esac

WORKSPACE="phase8c-$ENV"
TFC_ORG="palou-terraform-azure-1-12-phase8-c"
TFC_TOKEN_FILE="$HOME/.terraform.d/credentials.tfrc.json"
TFC_API="https://app.terraform.io/api/v2"

# Token TFC
TFC_TOKEN=$(python3 -c "
import json
with open('$TFC_TOKEN_FILE') as f:
    data = json.load(f)
print(data['credentials']['app.terraform.io']['token'])
" 2>/dev/null || echo "")

if [ -z "$TFC_TOKEN" ]; then
  echo "ERREUR : Token TFC introuvable. Exécutez : terraform login"
  exit 1
fi

# ==============================================================================
# AVERTISSEMENT
# ==============================================================================

echo ""
echo "  ========================================="
echo "  !!   DESTRUCTION IRREVERSIBLE          !!"
echo "  ========================================="
echo ""
echo "  Environnement : $ENV"
echo "  Workspace TFC : $WORKSPACE"
echo ""
echo "  Les ressources suivantes seront supprimées"
echo "  définitivement :"
echo "    - VM Flask et VM Monitoring"
echo "    - Azure Bastion"
echo "    - Service Bus Namespace (queues, topics, DLQ)"
echo "    - Event Hub Namespace (app-metrics, consumer groups)"
echo "    - Key Vault et ses secrets"
echo "    - Log Analytics Workspace et ses logs"
echo "    - VNet, subnets, NSGs"
echo "    - Private Endpoints et zones DNS privées"
echo "    - Resource Group rg-phase8c-$ENV"
echo ""

if [ "$ENV" = "prod" ]; then
  echo "  ATTENTION : Vous allez détruire la PRODUCTION."
  echo "  Cette action est IRREVERSIBLE."
  echo ""
fi

read -p "  Tapez '$ENV' pour confirmer : " CONFIRM
if [ "$CONFIRM" != "$ENV" ]; then
  echo "  Annulé."
  exit 0
fi

# ==============================================================================
# RÉCUPÉRATION DU WORKSPACE
# ==============================================================================

WS_ID=$(curl -s \
  --header "Authorization: Bearer $TFC_TOKEN" \
  "$TFC_API/organizations/$TFC_ORG/workspaces/$WORKSPACE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo "")

if [ -z "$WS_ID" ]; then
  echo "ERREUR : Workspace $WORKSPACE introuvable."
  exit 1
fi

echo ""
echo "  [OK] Workspace $WORKSPACE ($WS_ID)"

# ==============================================================================
# DÉCLENCHEMENT DU DESTROY
# ==============================================================================

echo "  Déclenchement du destroy dans TFC..."

RESPONSE=$(curl -s \
  --header "Authorization: Bearer $TFC_TOKEN" \
  --header "Content-Type: application/vnd.api+json" \
  --request POST \
  --data '{
    "data": {
      "type": "runs",
      "attributes": {
        "is-destroy": true,
        "message": "Destroy '"$ENV"' via destroy-env.sh"
      },
      "relationships": {
        "workspace": {
          "data": {
            "type": "workspaces",
            "id": "'"$WS_ID"'"
          }
        }
      }
    }
  }' \
  "$TFC_API/runs")

RUN_ID=$(echo "$RESPONSE" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo "")

if [ -n "$RUN_ID" ]; then
  echo "  [OK] Destroy lancé (Run ID: $RUN_ID)"
  echo ""
  echo "  IMPORTANT : Approuvez manuellement dans TFC :"
  echo "  https://app.terraform.io/app/$TFC_ORG/workspaces/$WORKSPACE/runs/$RUN_ID"
  echo ""
  echo "  Le destroy supprimera toutes les ressources Azure"
  echo "  de l'environnement $ENV, y compris le Service Bus,"
  echo "  l'Event Hub, le Key Vault et les VMs."
else
  echo "  [ERREUR] Échec du déclenchement du destroy."
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi
