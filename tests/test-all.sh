#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : tests/test-all.sh
# Description : Exécute tous les tests dans l'ordre pour un environnement.
#               Lance successivement :
#                 1. test-private-endpoint.sh  (résolution DNS privée)
#                 2. test-mi-auth.sh           (authentification Managed Identity)
#                 3. test-servicebus.sh        (connexion et opérations Service Bus)
#                 4. test-eventhub.sh          (connexion et opérations Event Hub)
#
#               Prérequis : tunnel Bastion ouvert vers la VM Flask
#               ET tunnel SSH avec port-forwarding vers Flask :5000.
#
# Usage :
#   ./tests/test-all.sh <env>
#   ./tests/test-all.sh dev
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

# Se placer à la racine du projet
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

RG="rg-phase8c-$ENV"
PROJECT_PREFIX="phase8c"

# ==============================================================================
# EN-TÊTE
# ==============================================================================

echo "============================================"
echo "  TESTS COMPLETS - PHASE 8C ($ENV)"
echo "============================================"
echo ""
echo "  Ce script exécute tous les tests dans l'ordre."
echo "  Un tunnel Bastion vers la VM Flask doit être"
echo "  ouvert avant de continuer."
echo ""
echo "  Terminal 1 — tunnel Bastion :"
echo ""
echo "    VM_APP_ID=\$(az vm show \\"
echo "      --resource-group $RG \\"
echo "      --name vm-${PROJECT_PREFIX}-${ENV}-app \\"
echo "      --query id -o tsv)"
echo ""
echo "    az network bastion tunnel \\"
echo "      --name bastion-${PROJECT_PREFIX}-${ENV} \\"
echo "      --resource-group $RG \\"
echo "      --target-resource-id \$VM_APP_ID \\"
echo "      --resource-port 22 \\"
echo "      --port 2223"
echo ""
echo "  Terminal 2 — tunnel SSH vers Flask :"
echo ""
echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \\"
echo "      -L 5000:localhost:5000 -N"
echo ""
read -p "  Les tunnels sont ouverts ? (o/n) : " TUNNEL_READY
if [ "$TUNNEL_READY" != "o" ] && [ "$TUNNEL_READY" != "O" ]; then
  echo "  Ouvrez les tunnels puis relancez ce script."
  exit 0
fi

echo ""

# ==============================================================================
# EXÉCUTION DES TESTS
# ==============================================================================

TOTAL_PASS=0
TOTAL_FAIL=0

run_test() {
  local script="$1"
  local label="$2"
  local step="$3"
  local total="$4"

  echo ""
  echo "============================================"
  echo "  TEST ${step}/${total} : $label"
  echo "============================================"
  echo ""

  if bash "$script" "$ENV"; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
    echo ""
    echo "  [OK] $label : réussi"
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    echo ""
    echo "  [ERREUR] $label : échoué"
    read -p "  Continuer quand même ? (o/n) : " CONTINUE
    if [ "$CONTINUE" != "o" ] && [ "$CONTINUE" != "O" ]; then
      echo ""
      echo "  Tests interrompus."
      echo "  Réussis : $TOTAL_PASS | Échoués : $TOTAL_FAIL"
      exit 1
    fi
  fi
}

run_test "tests/test-private-endpoint.sh" "Private Endpoints et DNS privés"       "1" "4"
run_test "tests/test-mi-auth.sh"          "Authentification Managed Identity"      "2" "4"
run_test "tests/test-servicebus.sh"       "Connexion et opérations Service Bus"    "3" "4"
run_test "tests/test-eventhub.sh"         "Connexion et opérations Event Hub"      "4" "4"

# ==============================================================================
# RÉSULTAT FINAL
# ==============================================================================

echo ""
echo "============================================"
echo "  RÉSULTAT FINAL ($ENV)"
echo "============================================"
echo ""
echo "  Réussis : $TOTAL_PASS / 4"
echo "  Échoués : $TOTAL_FAIL / 4"
echo ""

if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "  Tous les tests sont passés."
  echo "  L'environnement $ENV est fonctionnel."
  echo ""
  echo "  Prochaines étapes :"
  echo "    ./scripts/generate-traffic.sh $ENV 10"
  echo "    ./scripts/setup-monitoring.sh $ENV"
  exit 0
else
  echo "  $TOTAL_FAIL test(s) ont échoué."
  echo "  Consultez les logs de la VM Flask :"
  echo ""
  echo "    # Connexion via le tunnel Bastion ouvert"
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1"
  echo ""
  echo "    # Puis sur la VM"
  echo "    journalctl -u flask-app -n 100"
  echo "    journalctl -u eventhub-consumer -n 100"
  echo "    journalctl -u cloud-init -n 100"
  exit 1
fi
