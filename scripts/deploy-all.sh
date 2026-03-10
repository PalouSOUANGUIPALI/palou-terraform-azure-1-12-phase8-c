#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : deploy-all.sh
# Description : Déploie tous les environnements dans l'ordre :
#               1. dev
#               2. staging
#               3. prod
#
#               Guide l'utilisateur étape par étape et attend la
#               confirmation entre chaque environnement.
#               La stack monitoring est déployée séparément après
#               chaque environnement via setup-monitoring.sh.
#
# Prérequis :
#   - setup-azure.sh exécuté
#   - Git configuré et connecté au dépôt
#   - Azure CLI connecté (az login)
#   - Connexion à TFC (terraform login)
#
# Usage :
#   ./scripts/deploy-all.sh
#
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

set -euo pipefail

# Se placer à la racine du projet
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# ==============================================================================
# CONFIGURATION
# ==============================================================================

TFC_ORG="palou-terraform-azure-1-12-phase8-c"
TFC_TOKEN_FILE="$HOME/.terraform.d/credentials.tfrc.json"
TFC_API="https://app.terraform.io/api/v2"

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

deploy_environment() {
  local env="$1"
  local step="$2"
  local total="$3"
  local ws_name="phase8c-$env"
  local message="Phase 8C : déploiement $env"

  echo ""
  echo "============================================"
  echo "  ETAPE ${step}/${total} : $(echo "$env" | tr '[:lower:]' '[:upper:]')"
  echo "============================================"
  echo ""

  local ws_id
  ws_id=$(get_workspace_id "$ws_name")
  if [ -z "$ws_id" ]; then
    echo "  [ERREUR] Workspace $ws_name introuvable."
    return 1
  fi

  # Déclenchement du run
  echo "  Déclenchement du run..."
  local run_id
  run_id=$(trigger_run "$ws_id" "$message")

  if [ -z "$run_id" ]; then
    return 1
  fi

  echo "  [OK] Run déclenché : $run_id"
  echo "  https://app.terraform.io/app/$TFC_ORG/workspaces/$ws_name/runs/$run_id"
  echo ""

  # Attendre le plan
  wait_for_run "$run_id"
  local run_status=$?

  if [ $run_status -ne 0 ]; then
    echo "  Vérifiez le run dans TFC."
    read -p "  Continuer quand même ? (o/n) : " CONT
    if [ "$CONT" != "o" ] && [ "$CONT" != "O" ]; then
      return 1
    fi
  fi

  # Vérifier si approbation nécessaire
  local current_status
  current_status=$(curl -s \
    --header "Authorization: Bearer $TFC_TOKEN" \
    "$TFC_API/runs/$run_id" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['attributes']['status'])" \
    2>/dev/null || echo "unknown")

  if [ "$current_status" = "planned" ]; then
    echo ""
    if [ "$env" = "prod" ]; then
      echo "  C'est l'environnement de PRODUCTION."
      echo "  Vérifiez attentivement le plan avant d'approuver."
    fi
    echo "  Approuvez le plan dans TFC puis confirmez ici."
    read -p "  Infrastructure déployée ? (o/n) : " INFRA_DONE
    if [ "$INFRA_DONE" != "o" ] && [ "$INFRA_DONE" != "O" ]; then
      echo "  Etape sautée."
      return 0
    fi
  fi

  # Proposition de déployer le monitoring
  echo ""
  echo "  Infrastructure $env déployée."
  read -p "  Déployer la stack monitoring maintenant ? (o/n) : " MONITORING_NOW
  if [ "$MONITORING_NOW" = "o" ] || [ "$MONITORING_NOW" = "O" ]; then
    ./scripts/setup-monitoring.sh "$env"
  else
    echo "  [INFO] Stack monitoring à déployer manuellement :"
    echo "         ./scripts/setup-monitoring.sh $env"
  fi
}

# ==============================================================================
# VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

echo "============================================"
echo "  DEPLOIEMENT COMPLET - PHASE 8C"
echo "============================================"
echo ""
echo "  Ce script va déployer les 3 environnements"
echo "  dans l'ordre suivant :"
echo ""
echo "  1. dev     (Service Bus Standard, Event Hub 2 TU,"
echo "              VM Flask D2s_v6, VM Monitoring D2s_v6)"
echo "  2. staging (Service Bus Standard, Event Hub 2 TU,"
echo "              VM Flask D2s_v6, VM Monitoring D2s_v6)"
echo "  3. prod    (Service Bus Premium, Event Hub 4 TU,"
echo "              VM Flask D4s_v6, VM Monitoring D2s_v6)"
echo ""
echo "  Chaque étape nécessite une approbation"
echo "  manuelle dans Terraform Cloud."
echo ""
read -p "  Commencer ? (o/n) : " START
if [ "$START" != "o" ] && [ "$START" != "O" ]; then
  echo "  Annulé."
  exit 0
fi

# Token TFC
TFC_TOKEN=$(get_tfc_token)
if [ -z "$TFC_TOKEN" ]; then
  echo "  [ERREUR] Token TFC introuvable. Exécutez : terraform login"
  exit 1
fi
echo "  [OK] Token TFC"

# Azure CLI
if ! az account show &> /dev/null 2>&1; then
  echo "  [ERREUR] Non connecté à Azure. Exécutez : az login"
  exit 1
fi
echo "  [OK] Azure CLI connecté"

# Git push si nécessaire
if ! git diff --quiet || ! git diff --cached --quiet; then
  git add .
  git commit -m "Phase 8C : déploiement initial"
  git push
  echo "  [OK] Code poussé vers Git."
else
  echo "  [OK] Git à jour."
fi

# ==============================================================================
# CONFIRMATION PRODUCTION
# ==============================================================================

echo ""
echo "  ATTENTION : ce script inclut le déploiement"
echo "  de l'environnement de PRODUCTION."
echo "  Service Bus Premium, Event Hub 4 TU, VM D4s_v6."
echo "  Cela implique des couts Azure plus elevés."
echo ""
read -p "  Confirmer le déploiement prod ? (oui/non) : " PROD_CONFIRM
if [ "$PROD_CONFIRM" != "oui" ]; then
  echo ""
  echo "  Déploiement prod refusé."
  echo "  Utilisez deploy-dev.sh et deploy-staging.sh"
  echo "  pour déployer uniquement ces environnements."
  exit 0
fi

# ==============================================================================
# DÉPLOIEMENT DES ENVIRONNEMENTS
# ==============================================================================

deploy_environment "dev"     "1" "3"
deploy_environment "staging" "2" "3"
deploy_environment "prod"    "3" "3"

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo ""
echo "============================================"
echo "  DEPLOIEMENT COMPLET TERMINE"
echo "============================================"
echo ""
echo "  Prochaines étapes :"
echo ""
echo "  1. Valider les environnements :"
echo "     ./scripts/validate.sh dev"
echo "     ./scripts/validate.sh staging"
echo "     ./scripts/validate.sh prod"
echo ""
echo "  2. Générer du trafic :"
echo "     ./scripts/generate-traffic.sh dev 10"
echo ""
echo "  3. Accéder aux VMs via Bastion :"
echo "     az network bastion tunnel \\"
echo "       --name bastion-phase8c-dev \\"
echo "       --resource-group rg-phase8c-dev \\"
echo "       --target-resource-id <vm-id> \\"
echo "       --resource-port 22 \\"
echo "       --port 2222"
echo ""
echo "     ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1"
