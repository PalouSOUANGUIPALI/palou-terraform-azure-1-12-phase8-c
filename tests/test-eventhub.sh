#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : tests/test-eventhub.sh
# Description : Vérifie la connexion et les opérations Event Hub
#               depuis la VM Flask via tunnel Bastion.
#
#               Tests effectués :
#                 1. Namespace Event Hub accessible (état, SKU, TUs)
#                 2. Hub app-metrics et consumer group grafana
#                 3. Envoi de métriques vers Event Hub (/metrics/emit)
#                 4. Service eventhub-consumer actif sur la VM
#                 5. Métriques transmises au Pushgateway
#
#               Prérequis : tunnel Bastion ouvert vers la VM Flask
#               ET tunnel SSH avec port-forwarding vers Flask :5000.
#
# Usage :
#   ./tests/test-eventhub.sh <env>
#   ./tests/test-eventhub.sh dev
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
SSH_KEY="$HOME/.ssh/id_rsa_azure"
SSH_PORT_APP=2223
LOCAL_HOST="127.0.0.1"

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

ssh_vm() {
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i "$SSH_KEY" \
    -p "$SSH_PORT_APP" \
    "azureuser@$LOCAL_HOST" \
    "$@" 2>/dev/null
}

# ==============================================================================
# VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

echo "=== Test Event Hub - Phase 8C ($ENV) ==="
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

# Vérifier le tunnel Flask
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

# Vérifier accès SSH direct à la VM (port 2223 doit être ouvert)
SSH_ACTIVE=false
if [ -f "$SSH_KEY" ]; then
  if ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -i "$SSH_KEY" \
    -p "$SSH_PORT_APP" \
    "azureuser@$LOCAL_HOST" \
    "echo ok" &> /dev/null 2>&1; then
    SSH_ACTIVE=true
    echo "  [OK] SSH actif sur port $SSH_PORT_APP (tests VM disponibles)"
  else
    echo "  [INFO] SSH non actif sur port $SSH_PORT_APP — tests VM ignorés"
  fi
else
  echo "  [INFO] Clé SSH introuvable — tests VM ignorés"
fi

echo ""

# ==============================================================================
# TEST 1 : NAMESPACE EVENT HUB VIA AZURE CLI
# ==============================================================================

echo "--- Test 1 : Namespace Event Hub ---"

EH_NAMESPACE=$(az eventhubs namespace list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -z "$EH_NAMESPACE" ]; then
  fail "Event Hub Namespace introuvable dans $RG"
else
  EH_STATE=$(az eventhubs namespace show \
    --resource-group "$RG" \
    --name "$EH_NAMESPACE" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "")

  if [ "$EH_STATE" = "Succeeded" ]; then
    pass "Namespace $EH_NAMESPACE : Succeeded"
  else
    fail "Namespace $EH_NAMESPACE : ${EH_STATE:-inconnu}"
  fi

  EH_SKU=$(az eventhubs namespace show \
    --resource-group "$RG" \
    --name "$EH_NAMESPACE" \
    --query "sku.name" -o tsv 2>/dev/null || echo "")

  EH_TU=$(az eventhubs namespace show \
    --resource-group "$RG" \
    --name "$EH_NAMESPACE" \
    --query "sku.capacity" -o tsv 2>/dev/null || echo "")

  pass "SKU : $EH_SKU — Throughput Units : $EH_TU"

  EH_PUBLIC=$(az eventhubs namespace show \
    --resource-group "$RG" \
    --name "$EH_NAMESPACE" \
    --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "")

  if [ "$EH_PUBLIC" = "Disabled" ]; then
    pass "Accès public : désactivé (zero-trust)"
  else
    warn "Accès public : $EH_PUBLIC"
  fi
fi

echo ""

# ==============================================================================
# TEST 2 : HUB APP-METRICS ET CONSUMER GROUP
# ==============================================================================

echo "--- Test 2 : Hub app-metrics et consumer group grafana ---"

HUB_STATE=$(az eventhubs eventhub show \
  --resource-group "$RG" \
  --namespace-name "$EH_NAMESPACE" \
  --name "app-metrics" \
  --query "status" -o tsv 2>/dev/null || echo "")

if [ "$HUB_STATE" = "Active" ]; then
  pass "Event Hub app-metrics : Active"

  HUB_PARTITIONS=$(az eventhubs eventhub show \
    --resource-group "$RG" \
    --namespace-name "$EH_NAMESPACE" \
    --name "app-metrics" \
    --query "partitionCount" -o tsv 2>/dev/null || echo "")

  HUB_RETENTION=$(az eventhubs eventhub show \
    --resource-group "$RG" \
    --namespace-name "$EH_NAMESPACE" \
    --name "app-metrics" \
    --query "messageRetentionInDays" -o tsv 2>/dev/null || echo "")

  pass "Partitions : $HUB_PARTITIONS — Rétention : ${HUB_RETENTION}j"
else
  fail "Event Hub app-metrics : ${HUB_STATE:-introuvable}"
fi

# Consumer group grafana
CG_NAME=$(az eventhubs eventhub consumer-group show \
  --resource-group "$RG" \
  --namespace-name "$EH_NAMESPACE" \
  --eventhub-name "app-metrics" \
  --name "grafana" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [ -n "$CG_NAME" ]; then
  pass "Consumer group grafana : présent"
else
  fail "Consumer group grafana : introuvable"
  echo "  Le consumer group grafana est requis par consumer.py"
  echo "  pour lire les métriques depuis Event Hub."
fi

echo ""

# ==============================================================================
# TEST 3 : ENVOI DE MÉTRIQUES VERS EVENT HUB
# ==============================================================================

echo "--- Test 3 : Envoi de métriques vers Event Hub ---"

METRIC_DATA="{\"metric_name\": \"orders_processed\", \"value\": 42, \"tags\": {\"env\": \"$ENV\", \"test\": \"true\"}}"
EMIT_CODE=$(get_http_code "/metrics/emit" "POST" "$METRIC_DATA")

if [ "$EMIT_CODE" = "200" ] || [ "$EMIT_CODE" = "201" ]; then
  pass "POST /metrics/emit : HTTP $EMIT_CODE — métrique envoyée vers Event Hub"
  echo "  Métrique : orders_processed = 42"
  echo "  La métrique sera lue par consumer.py (consumer group grafana)"
  echo "  et transmise au Pushgateway pour affichage dans Grafana."
else
  fail "POST /metrics/emit : HTTP $EMIT_CODE"
  echo "  Causes possibles :"
  echo "    - Secret eventhub-connection-string non accessible via Key Vault"
  echo "    - Private Endpoint Event Hub non résolu"
  echo "    - NSG snet-app bloque le port AMQP 5671/5672"
fi

# Envoi de plusieurs métriques pour enrichir le test
for METRIC in "queue_depth:10" "consumer_lag:3" "processing_time:250"; do
  MNAME="${METRIC%%:*}"
  MVALUE="${METRIC##*:}"
  CODE=$(get_http_code "/metrics/emit" "POST" \
    "{\"metric_name\": \"$MNAME\", \"value\": $MVALUE, \"tags\": {\"env\": \"$ENV\"}}")
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    pass "Métrique $MNAME=$MVALUE : envoyée"
  else
    warn "Métrique $MNAME : HTTP $CODE"
  fi
done

echo ""

# ==============================================================================
# TEST 4 : SERVICE EVENTHUB-CONSUMER SUR LA VM
# ==============================================================================

echo "--- Test 4 : Service eventhub-consumer sur la VM Flask ---"

if $SSH_ACTIVE; then
  CONSUMER_STATUS=$(ssh_vm "systemctl is-active eventhub-consumer 2>/dev/null || echo inactive")

  if [ "$CONSUMER_STATUS" = "active" ]; then
    pass "Service eventhub-consumer : active"
  else
    fail "Service eventhub-consumer : $CONSUMER_STATUS"
    echo "  Vérifiez les logs du service :"
    echo "    journalctl -u eventhub-consumer -n 50"
  fi

  CONSUMER_ENABLED=$(ssh_vm "systemctl is-enabled eventhub-consumer 2>/dev/null || echo disabled")
  if [ "$CONSUMER_ENABLED" = "enabled" ]; then
    pass "Service eventhub-consumer : enabled au démarrage"
  else
    warn "Service eventhub-consumer : non enabled au démarrage ($CONSUMER_ENABLED)"
  fi

  # Vérifier les logs récents du consumer
  CONSUMER_ERRORS=$(ssh_vm \
    "journalctl -u eventhub-consumer -n 20 --no-pager 2>/dev/null \
    | grep -i 'error\|exception\|failed' | wc -l" || echo "0")

  if [ "$CONSUMER_ERRORS" -eq 0 ]; then
    pass "Logs eventhub-consumer : aucune erreur récente"
  else
    warn "Logs eventhub-consumer : $CONSUMER_ERRORS erreur(s) dans les 20 dernières lignes"
    echo "  Consultez : journalctl -u eventhub-consumer -n 50"
  fi
else
  warn "Service eventhub-consumer : SSH non actif — test ignoré"
  echo "  Pour vérifier, connectez-vous à la VM :"
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1"
  echo "    systemctl status eventhub-consumer"
fi

echo ""

# ==============================================================================
# TEST 5 : MÉTRIQUES TRANSMISES AU PUSHGATEWAY
# ==============================================================================

echo "--- Test 5 : Métriques transmises au Pushgateway ---"

if $SSH_ACTIVE; then
  # Vérifier que le Pushgateway est accessible depuis la VM Flask
  # IP de la VM Monitoring dans snet-monitoring

  VM_MONITORING_IP=$(az vm show \
    --resource-group "$RG" \
    --name "vm-${PROJECT_PREFIX}-${ENV}-monitoring" \
    --show-details \
    --query "privateIps" -o tsv 2>/dev/null || echo "")

  if [ -n "$VM_MONITORING_IP" ]; then
    PUSHGATEWAY_URL="http://${VM_MONITORING_IP}:9091"

    # Tester la connectivité Pushgateway depuis la VM Flask
    PGW_CODE=$(ssh_vm \
      "curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 \
      '$PUSHGATEWAY_URL/metrics' 2>/dev/null || echo '000'")

    if [ "$PGW_CODE" = "200" ]; then
      pass "Pushgateway accessible depuis VM Flask : HTTP 200"
      echo "  URL : $PUSHGATEWAY_URL"

      # Vérifier si des métriques ont été poussées
      PGW_METRICS=$(ssh_vm \
        "curl -s '$PUSHGATEWAY_URL/metrics' 2>/dev/null \
        | grep -c 'eventhub\|orders\|queue' || echo '0'")

      if [ "$PGW_METRICS" -gt 0 ]; then
        pass "Métriques Event Hub trouvées dans Pushgateway : $PGW_METRICS ligne(s)"
      else
        warn "Aucune métrique Event Hub dans Pushgateway"
        echo "  Le consumer peut encore traiter les événements envoyés au test 3."
        echo "  Attendez quelques secondes et vérifiez :"
        echo "    curl http://$VM_MONITORING_IP:9091/metrics | grep orders"
      fi
    elif [ "$PGW_CODE" = "000" ]; then
      warn "Pushgateway non accessible depuis VM Flask ($VM_MONITORING_IP:9091)"
      echo "  Vérifiez que setup-monitoring.sh a été exécuté pour cet environnement."
      echo "  Vérifiez le NSG snet-app : outbound TCP 9091 vers snet-monitoring."
    else
      warn "Pushgateway : HTTP $PGW_CODE depuis VM Flask"
    fi
  else
    warn "VM Monitoring introuvable dans $RG — test Pushgateway ignoré"
  fi
else
  warn "SSH non actif — test Pushgateway ignoré"
  echo "  Ouvrez le tunnel Bastion sur port 2223 pour ce test."
fi

echo ""

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo "=== Résultat Event Hub ($ENV) ==="
echo ""
echo "  Réussies  : $OK"
echo "  Avertiss. : $WARN"
echo "  Échouées  : $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  Event Hub opérationnel."
  echo "  Hub app-metrics, consumer group grafana et envoi de métriques fonctionnels."
  echo ""
  echo "  Pour visualiser les métriques dans Grafana :"
  echo "    ./scripts/setup-monitoring.sh $ENV"
  exit 0
else
  echo "  $FAIL problème(s) détecté(s)."
  echo "  Consultez les logs de la VM Flask :"
  echo ""
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1"
  echo "    journalctl -u flask-app -n 100"
  echo "    journalctl -u eventhub-consumer -n 100"
  exit 1
fi
