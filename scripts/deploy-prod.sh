#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : deploy-prod.sh
# Description : Déclenche le déploiement de l'environnement prod via
#               l'API Terraform Cloud.
#
#               Ce script :
#                 1. Vérifie les prérequis
#                 2. Demande une confirmation explicite avant de continuer
#                 3. Pousse le code vers Git (si changements)
#                 4. Déclenche un run dans TFC via l'API
#                 5. Attend le plan et affiche le lien d'approbation
#
#               Pas de déploiement d'application séparé :
#               la VM Flask est configurée entièrement via cloud-init
#               au moment du terraform apply.
#               La stack monitoring est déployée séparément via :
#                 ./scripts/setup-monitoring.sh prod
#
# Prérequis :
#   - setup-azure.sh exécuté
#   - deploy-staging.sh validé
#   - Git configuré et connecté au dépôt
#   - Azure CLI connecté (az login)
#   - Connexion à TFC (terraform login)
#
# Usage :
#   ./scripts/deploy-prod.sh
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# ==============================================================================
# CONFIGURATION
# ==============================================================================

ENV="prod"
TFC_ORG="palou-terraform-azure-1-12-phase8-c"
TFC_TOKEN_FILE="$HOME/.terraform.d/credentials.tfrc.json"
TFC_API="https://app.terraform.io/api/v2"
WORKSPACE="phase8c-$ENV"
ENV_DIR="environments/$ENV"

# ==============================================================================
# FONCTIONS
# ==============================================================================

get_tfc_token() {
  python3 -c "
import json
with open('$TFC_TOKEN_FILE') as f:
    data = json.load(f)
print(data['credentials']['app.terraform.io']['token'])
" 2>/dev/null || echo ""
}

get_workspace_id() {
  local ws_name="$1"
  curl -s \
    --header "Authorization: Bearer $TFC_TOKEN" \
    "$TFC_API/organizations/$TFC_ORG/workspaces/$ws_name" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo ""
}

trigger_run() {
  local ws_id="$1"
  local message="$2"

  local RESPONSE
  RESPONSE=$(printf '%s' "$message" | python3 -c "
import json, sys
message = sys.stdin.read()
payload = json.dumps({
    'data': {
        'type': 'runs',
        'attributes': {
            'message': message,
            'auto-apply': False
        },
        'relationships': {
            'workspace': {
                'data': {
                    'type': 'workspaces',
                    'id': '$ws_id'
                }
            }
        }
    }
})
print(payload)
" | curl -s \
    --header "Authorization: Bearer $TFC_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --request POST \
    --data @- \
    "$TFC_API/runs")

  local RUN_ID
  RUN_ID=$(echo "$RESPONSE" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo "")

  if [ -n "$RUN_ID" ]; then
    echo "$RUN_ID"
  else
    echo ""
    echo "  [ERREUR] Échec du déclenchement du run."
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "  $RESPONSE"
    return 1
  fi
}

wait_for_run() {
  local run_id="$1"
  local max_wait=600
  local elapsed=0

  echo "  Attente du plan..."
  while [ $elapsed -lt $max_wait ]; do
    local STATUS
    STATUS=$(curl -s \
      --header "Authorization: Bearer $TFC_TOKEN" \
      "$TFC_API/runs/$run_id" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['status'])" 2>/dev/null \
      || echo "unknown")

    case "$STATUS" in
      "planned")
        echo "  [OK] Plan terminé. Approuvez dans TFC."
        return 0
        ;;
      "applied")
        echo "  [OK] Apply terminé."
        return 0
        ;;
      "planned_and_finished")
        echo "  [OK] Plan terminé (aucun changement)."
        return 0
        ;;
      "errored")
        echo "  [ERREUR] Le run a échoué."
        return 1
        ;;
      "canceled"|"discarded")
        echo "  [INFO] Run annulé."
        return 1
        ;;
      *)
        sleep 10
        elapsed=$((elapsed + 10))
        ;;
    esac
  done

  echo "  [INFO] Timeout après ${max_wait}s. Vérifiez dans TFC."
  return 1
}

# ==============================================================================
# VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

echo "=== Déploiement de l'environnement PROD ==="
echo ""
echo "--- Vérification des prérequis ---"

if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
  echo "  [ERREUR] Ce répertoire n'est pas un dépôt Git."
  exit 1
fi
echo "  [OK] Dépôt Git"

if [ ! -d "$ENV_DIR" ]; then
  echo "  [ERREUR] Répertoire $ENV_DIR introuvable."
  exit 1
fi
echo "  [OK] Répertoire $ENV_DIR"

TFC_TOKEN=$(get_tfc_token)
if [ -z "$TFC_TOKEN" ]; then
  echo "  [ERREUR] Token TFC introuvable. Exécutez : terraform login"
  exit 1
fi
echo "  [OK] Token TFC"

WS_ID=$(get_workspace_id "$WORKSPACE")
if [ -z "$WS_ID" ]; then
  echo "  [ERREUR] Workspace $WORKSPACE introuvable."
  echo "           Exécutez d'abord : ./scripts/setup-azure.sh"
  exit 1
fi
echo "  [OK] Workspace $WORKSPACE ($WS_ID)"

if ! command -v az &> /dev/null; then
  echo "  [ERREUR] Azure CLI non installé."
  exit 1
fi

if ! az account show &> /dev/null 2>&1; then
  echo "  [ERREUR] Non connecté à Azure. Exécutez : az login"
  exit 1
fi
echo "  [OK] Azure CLI connecté"

echo ""

# ==============================================================================
# CONFIRMATION PROD
# ==============================================================================

echo "--- Confirmation déploiement PROD ---"
echo ""
echo "  ATTENTION : vous allez déployer en PRODUCTION."
echo "  Service Bus SKU Premium, Event Hub 4 TU, VM D4s_v6."
echo "  Cela implique des couts Azure plus elevés."
echo ""
read -p "  Confirmer le déploiement en PROD ? (oui/non) : " PROD_CONFIRM

if [ "$PROD_CONFIRM" != "oui" ]; then
  echo ""
  echo "  [INFO] Déploiement annulé."
  exit 0
fi

echo ""

# ==============================================================================
# GIT PUSH
# ==============================================================================

echo "--- Git ---"

if git diff --quiet && git diff --cached --quiet; then
  echo "  [INFO] Aucun changement local à committer."
else
  read -p "  Committer et pousser les changements ? (o/n) : " CONFIRM
  if [ "$CONFIRM" = "o" ] || [ "$CONFIRM" = "O" ]; then
    git add .
    git commit -m "Phase 8C : déploiement $ENV"
    git push
    echo "  [OK] Changements poussés."
  else
    echo "  [INFO] Changements non poussés."
  fi
fi

echo ""

# ==============================================================================
# DÉCLENCHEMENT DU RUN TFC
# ==============================================================================

echo "--- Déclenchement du run dans TFC ---"

RUN_ID=$(trigger_run "$WS_ID" "Phase 8C : déploiement $ENV")

if [ -z "$RUN_ID" ]; then
  exit 1
fi

echo "  [OK] Run déclenché : $RUN_ID"
echo ""
echo "  Lien vers le run :"
echo "  https://app.terraform.io/app/$TFC_ORG/workspaces/$WORKSPACE/runs/$RUN_ID"
echo ""

# ==============================================================================
# ATTENTE DU PLAN
# ==============================================================================

wait_for_run "$RUN_ID"
RUN_STATUS=$?

if [ $RUN_STATUS -ne 0 ]; then
  echo "  Vérifiez le run dans TFC puis relancez ce script."
  exit 1
fi

CURRENT_STATUS=$(curl -s \
  --header "Authorization: Bearer $TFC_TOKEN" \
  "$TFC_API/runs/$RUN_ID" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['status'])" \
  2>/dev/null || echo "unknown")

if [ "$CURRENT_STATUS" = "planned" ]; then
  echo ""
  echo "  Le plan nécessite une approbation manuelle dans TFC."
  echo "  Approuvez le plan puis confirmez ici."
  echo ""
  read -p "  L'infrastructure est-elle déployée ? (o/n) : " INFRA_DONE

  if [ "$INFRA_DONE" != "o" ] && [ "$INFRA_DONE" != "O" ]; then
    echo ""
    echo "  Approuvez le plan dans TFC puis relancez ce script."
    exit 0
  fi
fi

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo ""
echo "=== Déploiement PROD terminé ==="
echo ""
echo "  La VM Flask et la VM Monitoring sont configurées via cloud-init."
echo "  Quelques minutes peuvent être nécessaires pour que cloud-init termine."
echo ""
echo "  Déployer la stack monitoring :"
echo "    ./scripts/setup-monitoring.sh prod"
echo ""
echo "  Vérifier l'état de l'infrastructure :"
echo "    ./scripts/validate.sh prod"
echo ""
echo "  Générer du trafic :"
echo "    ./scripts/generate-traffic.sh prod 10"
