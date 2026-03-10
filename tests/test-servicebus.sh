#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : tests/test-servicebus.sh
# Description : Vérifie la connexion et les opérations Service Bus
#               depuis la VM Flask via tunnel Bastion.
#
#               Tests effectués :
#                 1. Namespace Service Bus accessible (état, SKU)
#                 2. Envoi d'un message dans la queue orders (/send)
#                 3. Réception d'un message de la queue orders (/receive)
#                 4. Publication sur le topic events - niveau info (/publish)
#                 5. Publication sur le topic events - niveau critical (/publish)
#                 6. Lecture abonnement sub-logs (/subscribe/sub-logs)
#                 7. Lecture abonnement sub-alerts (/subscribe/sub-alerts)
#                 8. Lecture dead-letter queue (/dlq)
#
#               Prérequis : tunnel Bastion ouvert vers la VM Flask
#               ET tunnel SSH avec port-forwarding vers Flask :5000.
#
# Usage :
#   ./tests/test-servicebus.sh <env>
#   ./tests/test-servicebus.sh dev
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

# ==============================================================================
# CONFIGURATION
# ==============================================================================

BASE_URL="http://localhost:5000"
RG="rg-phase8c-$ENV"
PROJECT_PREFIX="phase8c"

# ==============================================================================
# FONCTIONS
# ==============================================================================

OK=0
FAIL=0
WARN=0

pass() { echo "  [OK]     $1"; OK=$((OK + 1)); }
fail() { echo "  [ERREUR] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [ATTEN.] $1"; WARN=$((WARN + 1)); }

get_http_code() {
  local path="$1"
  local method="${2:-GET}"
  local data="${3:-}"

  if [ -n "$data" ]; then
    curl -s -o /dev/null -w "%{http_code}" \
      -X "$method" \
      -H "Content-Type: application/json" \
      -d "$data" \
      --max-time 15 \
      "$BASE_URL$path" 2>/dev/null || echo "000"
  else
    curl -s -o /dev/null -w "%{http_code}" \
      -X "$method" \
      --max-time 15 \
      "$BASE_URL$path" 2>/dev/null || echo "000"
  fi
}

call_endpoint() {
  local path="$1"
  local method="${2:-GET}"
  local data="${3:-}"

  if [ -n "$data" ]; then
    curl -s \
      -X "$method" \
      -H "Content-Type: application/json" \
      -d "$data" \
      --max-time 15 \
      "$BASE_URL$path" 2>/dev/null || echo ""
  else
    curl -s \
      -X "$method" \
      --max-time 15 \
      "$BASE_URL$path" 2>/dev/null || echo ""
  fi
}

# ==============================================================================
# VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

echo "=== Test Service Bus - Phase 8C ($ENV) ==="
echo ""

if ! command -v az &> /dev/null; then
  echo "  [ERREUR] Azure CLI non installé."
  exit 1
fi

if ! az account show &> /dev/null 2>&1; then
  echo "  [ERREUR] Non connecté à Azure. Exécutez : az login"
  exit 1
fi

if ! command -v python3 &> /dev/null; then
  echo "  [ERREUR] python3 non installé."
  exit 1
fi

# Vérifier le tunnel
HEALTH_CODE=$(get_http_code "/health")
if [ "$HEALTH_CODE" = "000" ]; then
  echo "  [ERREUR] Tunnel non actif sur localhost:5000"
  echo ""
  echo "  Ouvrez les tunnels dans deux terminaux séparés :"
  echo ""
  echo "  Terminal 1 — tunnel Bastion :"
  echo "    az network bastion tunnel \\"
  echo "      --name bastion-${PROJECT_PREFIX}-${ENV} \\"
  echo "      --resource-group $RG \\"
  echo "      --target-resource-id <vm-app-id> \\"
  echo "      --resource-port 22 --port 2223"
  echo ""
  echo "  Terminal 2 — tunnel SSH :"
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \\"
  echo "      -L 5000:localhost:5000 -N"
  exit 1
fi

echo "  [OK] Tunnel actif sur localhost:5000"
echo ""

# ==============================================================================
# TEST 1 : NAMESPACE SERVICE BUS VIA AZURE CLI
# ==============================================================================

echo "--- Test 1 : Namespace Service Bus ---"

SB_NAME=$(az servicebus namespace list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -z "$SB_NAME" ]; then
  fail "Service Bus Namespace introuvable dans $RG"
else
  SB_STATE=$(az servicebus namespace show \
    --resource-group "$RG" \
    --name "$SB_NAME" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "")

  if [ "$SB_STATE" = "Succeeded" ]; then
    pass "Namespace $SB_NAME : Succeeded"
  else
    fail "Namespace $SB_NAME : ${SB_STATE:-inconnu}"
  fi

  SB_SKU=$(az servicebus namespace show \
    --resource-group "$RG" \
    --name "$SB_NAME" \
    --query "sku.name" -o tsv 2>/dev/null || echo "")
  pass "SKU : $SB_SKU"

  SB_LOCAL_AUTH=$(az servicebus namespace show \
    --resource-group "$RG" \
    --name "$SB_NAME" \
    --query "disableLocalAuth" -o tsv 2>/dev/null || echo "")

  if [ "$SB_LOCAL_AUTH" = "true" ]; then
    pass "Auth locale désactivée : local_auth_enabled = false"
  else
    warn "Auth locale non désactivée — vérifiez local_auth_enabled dans Terraform"
  fi

  # Queue orders
  QUEUE_COUNT=$(az servicebus queue show \
    --resource-group "$RG" \
    --namespace-name "$SB_NAME" \
    --name "orders" \
    --query "status" -o tsv 2>/dev/null || echo "")

  if [ "$QUEUE_COUNT" = "Active" ]; then
    pass "Queue orders : Active"
  else
    fail "Queue orders : ${QUEUE_COUNT:-introuvable}"
  fi

  # Topic events
  TOPIC_STATE=$(az servicebus topic show \
    --resource-group "$RG" \
    --namespace-name "$SB_NAME" \
    --name "events" \
    --query "status" -o tsv 2>/dev/null || echo "")

  if [ "$TOPIC_STATE" = "Active" ]; then
    pass "Topic events : Active"
  else
    fail "Topic events : ${TOPIC_STATE:-introuvable}"
  fi

  # Abonnements
  for SUB in "sub-logs" "sub-alerts"; do
    SUB_STATE=$(az servicebus topic subscription show \
      --resource-group "$RG" \
      --namespace-name "$SB_NAME" \
      --topic-name "events" \
      --name "$SUB" \
      --query "status" -o tsv 2>/dev/null || echo "")

    if [ "$SUB_STATE" = "Active" ]; then
      pass "Abonnement $SUB : Active"
    else
      fail "Abonnement $SUB : ${SUB_STATE:-introuvable}"
    fi
  done
fi

echo ""

# ==============================================================================
# TEST 2 : ENVOI MESSAGE QUEUE ORDERS
# ==============================================================================

echo "--- Test 2 : Envoi message queue orders ---"

SEND_DATA="{\"order_id\": \"test-$(date +%s)\", \"product\": \"test-item\", \"quantity\": 1}"
SEND_CODE=$(get_http_code "/send" "POST" "$SEND_DATA")

if [ "$SEND_CODE" = "200" ] || [ "$SEND_CODE" = "201" ]; then
  pass "POST /send : HTTP $SEND_CODE — message envoyé dans queue orders"
else
  fail "POST /send : HTTP $SEND_CODE"
  echo "  Causes possibles :"
  echo "    - Secret servicebus-connection-string non accessible via Key Vault"
  echo "    - Private Endpoint Service Bus non résolu"
  echo "    - NSG snet-app bloque le port AMQP 5671/5672"
fi

echo ""

# ==============================================================================
# TEST 3 : RÉCEPTION MESSAGE QUEUE ORDERS
# ==============================================================================

echo "--- Test 3 : Réception message queue orders ---"

RECEIVE_CODE=$(get_http_code "/receive" "GET")
RECEIVE_RESPONSE=$(call_endpoint "/receive" "GET")

if [ "$RECEIVE_CODE" = "200" ]; then
  MSG_RECEIVED=$(echo "$RECEIVE_RESPONSE" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','none'))" \
    2>/dev/null || echo "none")

  if [ "$MSG_RECEIVED" != "none" ] && [ "$MSG_RECEIVED" != "null" ] && [ -n "$MSG_RECEIVED" ]; then
    pass "GET /receive : HTTP 200 — message reçu et acquitté"
  else
    pass "GET /receive : HTTP 200 — queue vide (normal si message déjà consommé)"
  fi
elif [ "$RECEIVE_CODE" = "204" ]; then
  pass "GET /receive : HTTP 204 — queue vide"
else
  fail "GET /receive : HTTP $RECEIVE_CODE"
fi

echo ""

# ==============================================================================
# TEST 4 : PUBLICATION TOPIC EVENTS — NIVEAU INFO
# ==============================================================================

echo "--- Test 4 : Publication topic events (niveau info) ---"

PUBLISH_INFO="{\"event\": \"order-processed\", \"level\": \"info\", \"order_id\": \"test-$(date +%s)\"}"
PUBLISH_INFO_CODE=$(get_http_code "/publish" "POST" "$PUBLISH_INFO")

if [ "$PUBLISH_INFO_CODE" = "200" ] || [ "$PUBLISH_INFO_CODE" = "201" ]; then
  pass "POST /publish (info) : HTTP $PUBLISH_INFO_CODE — message publié sur topic events"
  echo "  application_properties : {level: 'info'}"
  echo "  Routage : sub-logs (filtre : aucun — tous les messages)"
else
  fail "POST /publish (info) : HTTP $PUBLISH_INFO_CODE"
  echo "  Causes possibles :"
  echo "    - Secret servicebus-connection-string non accessible"
  echo "    - Topic events introuvable"
fi

echo ""

# ==============================================================================
# TEST 5 : PUBLICATION TOPIC EVENTS — NIVEAU CRITICAL
# ==============================================================================

echo "--- Test 5 : Publication topic events (niveau critical) ---"

PUBLISH_CRITICAL="{\"event\": \"payment-failed\", \"level\": \"critical\", \"order_id\": \"test-$(date +%s)\"}"
PUBLISH_CRITICAL_CODE=$(get_http_code "/publish" "POST" "$PUBLISH_CRITICAL")

if [ "$PUBLISH_CRITICAL_CODE" = "200" ] || [ "$PUBLISH_CRITICAL_CODE" = "201" ]; then
  pass "POST /publish (critical) : HTTP $PUBLISH_CRITICAL_CODE — message publié"
  echo "  application_properties : {level: 'critical'}"
  echo "  Routage : sub-logs (tous) + sub-alerts (filtre SQL : level = 'critical')"
else
  fail "POST /publish (critical) : HTTP $PUBLISH_CRITICAL_CODE"
fi

echo ""

# ==============================================================================
# TEST 6 : LECTURE ABONNEMENT SUB-LOGS
# ==============================================================================

echo "--- Test 6 : Lecture abonnement sub-logs ---"

SUB_LOGS_CODE=$(get_http_code "/subscribe/sub-logs" "GET")
SUB_LOGS_RESPONSE=$(call_endpoint "/subscribe/sub-logs" "GET")

if [ "$SUB_LOGS_CODE" = "200" ]; then
  MSG_COUNT=$(echo "$SUB_LOGS_RESPONSE" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count', 0))" \
    2>/dev/null || echo "0")
  pass "GET /subscribe/sub-logs : HTTP 200 — $MSG_COUNT message(s) reçu(s)"
elif [ "$SUB_LOGS_CODE" = "204" ]; then
  pass "GET /subscribe/sub-logs : HTTP 204 — abonnement vide"
else
  fail "GET /subscribe/sub-logs : HTTP $SUB_LOGS_CODE"
fi

echo ""

# ==============================================================================
# TEST 7 : LECTURE ABONNEMENT SUB-ALERTS
# ==============================================================================

echo "--- Test 7 : Lecture abonnement sub-alerts ---"

SUB_ALERTS_CODE=$(get_http_code "/subscribe/sub-alerts" "GET")
SUB_ALERTS_RESPONSE=$(call_endpoint "/subscribe/sub-alerts" "GET")

if [ "$SUB_ALERTS_CODE" = "200" ]; then
  MSG_COUNT=$(echo "$SUB_ALERTS_RESPONSE" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count', 0))" \
    2>/dev/null || echo "0")
  pass "GET /subscribe/sub-alerts : HTTP 200 — $MSG_COUNT message(s) reçu(s)"
  echo "  Filtre SQL actif : level = 'critical' uniquement"
elif [ "$SUB_ALERTS_CODE" = "204" ]; then
  pass "GET /subscribe/sub-alerts : HTTP 204 — abonnement vide"
  echo "  Normal si aucun message critical publié."
else
  fail "GET /subscribe/sub-alerts : HTTP $SUB_ALERTS_CODE"
fi

echo ""

# ==============================================================================
# TEST 8 : LECTURE DEAD-LETTER QUEUE
# ==============================================================================

echo "--- Test 8 : Lecture dead-letter queue ---"

DLQ_CODE=$(get_http_code "/dlq" "GET")
DLQ_RESPONSE=$(call_endpoint "/dlq" "GET")

if [ "$DLQ_CODE" = "200" ]; then
  DLQ_COUNT=$(echo "$DLQ_RESPONSE" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count', 0))" \
    2>/dev/null || echo "0")

  if [ "$DLQ_COUNT" -gt 0 ]; then
    warn "GET /dlq : HTTP 200 — $DLQ_COUNT message(s) en dead-letter"
    echo "  Des messages n'ont pas pu être traités après max_delivery_count tentatives."
    echo "  Endpoint /dlq/reprocess disponible pour rejouer les messages."
  else
    pass "GET /dlq : HTTP 200 — dead-letter queue vide"
  fi
elif [ "$DLQ_CODE" = "204" ]; then
  pass "GET /dlq : HTTP 204 — dead-letter queue vide"
else
  fail "GET /dlq : HTTP $DLQ_CODE"
fi

echo ""

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo "=== Résultat Service Bus ($ENV) ==="
echo ""
echo "  Réussies  : $OK"
echo "  Avertiss. : $WARN"
echo "  Échouées  : $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  Service Bus opérationnel."
  echo "  Queue orders, topic events et abonnements fonctionnels."
  exit 0
else
  echo "  $FAIL problème(s) détecté(s)."
  echo "  Consultez les logs de la VM Flask :"
  echo ""
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1"
  echo "    journalctl -u flask-app -n 100"
  exit 1
fi
