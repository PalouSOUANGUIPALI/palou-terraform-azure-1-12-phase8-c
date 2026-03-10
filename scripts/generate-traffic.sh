#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : generate-traffic.sh
# Description : Génère du trafic de test sur la VM Flask via tunnel Bastion.
#               Envoie des requêtes sur tous les endpoints de l'application :
#                 - /health              : vérification de l'état
#                 - /send                : envoi message queue orders
#                 - /receive             : réception message queue orders
#                 - /publish             : publication topic events
#                 - /subscribe/sub-logs  : lecture abonnement logs
#                 - /subscribe/sub-alerts: lecture abonnement alerts (critical)
#                 - /metrics/emit        : envoi métriques vers Event Hub
#                 - /dlq                 : lecture dead-letter queue
#
#               Le trafic génère des métriques visibles dans Grafana
#               via Prometheus Pushgateway.
#
# Prérequis :
#   - VM Flask déployée et cloud-init terminé
#   - Azure CLI installé et connecté (az login)
#   - Clé SSH : ~/.ssh/id_rsa_azure
#
# Usage :
#   ./scripts/generate-traffic.sh <env> [iterations]
#   Exemple : ./scripts/generate-traffic.sh dev 10
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

ENV="${1:-}"
ITERATIONS="${2:-5}"
SSH_KEY="$HOME/.ssh/id_rsa_azure"
SSH_PORT_APP=2223
LOCAL_HOST="127.0.0.1"
FLASK_PORT=5000
FLASK_URL="http://$LOCAL_HOST:$FLASK_PORT"
BASTION_TUNNEL_PID=""
SSH_TUNNEL_PID=""

# ==============================================================================
# NETTOYAGE À LA SORTIE
# ==============================================================================

cleanup() {
  echo ""
  if [ -n "$SSH_TUNNEL_PID" ]; then
    kill "$SSH_TUNNEL_PID" 2>/dev/null || true
  fi
  if [ -n "$BASTION_TUNNEL_PID" ]; then
    echo "  Fermeture du tunnel Bastion..."
    kill "$BASTION_TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ==============================================================================
# FONCTIONS UTILITAIRES
# ==============================================================================

separator() {
  echo ""
  echo "============================================"
  echo "  $1"
  echo "============================================"
  echo ""
}

success() { echo "  [OK]     $1"; }
error()   { echo "  [ERREUR] $1"; }
info()    { echo "  [INFO]   $1"; }
warn()    { echo "  [ATTEN.] $1"; }

usage() {
  echo ""
  echo "  Usage : ./scripts/generate-traffic.sh <env> [iterations]"
  echo "  Environnements valides : dev, staging, prod"
  echo "  iterations : nombre de cycles (défaut : 5)"
  echo ""
  exit 1
}

call_endpoint() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local description="$4"

  local http_code
  if [ -n "$data" ]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X "$method" \
      -H "Content-Type: application/json" \
      -d "$data" \
      --connect-timeout 5 \
      "$FLASK_URL$path" 2>/dev/null || echo "000")
  else
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X "$method" \
      --connect-timeout 5 \
      "$FLASK_URL$path" 2>/dev/null || echo "000")
  fi

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    success "$description : HTTP $http_code"
  elif [ "$http_code" = "000" ]; then
    warn "$description : pas de réponse"
  else
    warn "$description : HTTP $http_code"
  fi
}

# ==============================================================================
# VÉRIFICATION DES ARGUMENTS
# ==============================================================================

if [ -z "$ENV" ]; then
  error "Environnement non spécifié."
  usage
fi

if [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  error "Environnement invalide : $ENV"
  usage
fi

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
  error "Nombre d'itérations invalide : $ITERATIONS"
  usage
fi

RESOURCE_GROUP="rg-phase8c-$ENV"
PROJECT_PREFIX="phase8c"
BASTION_NAME="bastion-${PROJECT_PREFIX}-${ENV}"

separator "GÉNÉRATION DE TRAFIC — $ENV ($ITERATIONS itérations)"

# ==============================================================================
# PHASE 1 : VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

separator "PHASE 1 : Vérification des prérequis"

if ! command -v az &> /dev/null; then
  error "Azure CLI non installé."
  exit 1
fi
if ! az account show &> /dev/null 2>&1; then
  error "Non connecté à Azure. Exécutez : az login"
  exit 1
fi
success "Azure CLI connecté"

if [ ! -f "$SSH_KEY" ]; then
  error "Clé SSH introuvable : $SSH_KEY"
  exit 1
fi
success "Clé SSH : $SSH_KEY"

if ! command -v curl &> /dev/null; then
  error "curl non installé."
  exit 1
fi
success "curl disponible"

# ==============================================================================
# PHASE 2 : RÉCUPÉRATION DES RESSOURCES AZURE
# ==============================================================================

separator "PHASE 2 : Récupération des ressources Azure"

VM_APP_NAME="vm-${PROJECT_PREFIX}-${ENV}-app"
VM_APP_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_APP_NAME" \
  --query "id" -o tsv 2>/dev/null || echo "")

if [ -z "$VM_APP_ID" ]; then
  error "VM Flask '$VM_APP_NAME' introuvable."
  echo "  Vérifiez que le déploiement Terraform est terminé."
  exit 1
fi
success "VM Flask : $VM_APP_NAME"

# ==============================================================================
# PHASE 3 : TUNNEL BASTION
# ==============================================================================

separator "PHASE 3 : Ouverture du tunnel Bastion"

# Fermeture d'un éventuel tunnel existant sur le même port
if lsof -ti:"$SSH_PORT_APP" &> /dev/null; then
  info "Port $SSH_PORT_APP déjà utilisé — fermeture du tunnel existant..."
  kill "$(lsof -ti:"$SSH_PORT_APP")" 2>/dev/null || true
  sleep 2
fi

az network bastion tunnel \
  --name "$BASTION_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --target-resource-id "$VM_APP_ID" \
  --resource-port 22 \
  --port "$SSH_PORT_APP" &

BASTION_TUNNEL_PID=$!
info "Tunnel Bastion PID : $BASTION_TUNNEL_PID"
info "Attente de l'établissement du tunnel (15s)..."
sleep 15

if ! kill -0 "$BASTION_TUNNEL_PID" 2>/dev/null; then
  error "Le tunnel Bastion ne s'est pas établi correctement."
  exit 1
fi
success "Tunnel Bastion actif sur port $SSH_PORT_APP"

# ==============================================================================
# PHASE 4 : TUNNEL SSH VERS FLASK
# ==============================================================================

separator "PHASE 4 : Tunnel SSH vers Flask"

# Fermeture d'un éventuel tunnel SSH existant sur le port Flask
if lsof -ti:"$FLASK_PORT" &> /dev/null; then
  info "Port $FLASK_PORT déjà utilisé — fermeture..."
  kill "$(lsof -ti:"$FLASK_PORT")" 2>/dev/null || true
  sleep 2
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $SSH_PORT_APP"

ssh $SSH_OPTS \
  -L "${FLASK_PORT}:localhost:${FLASK_PORT}" \
  -N \
  "azureuser@$LOCAL_HOST" &

SSH_TUNNEL_PID=$!
info "Tunnel SSH PID : $SSH_TUNNEL_PID"
info "Attente de l'établissement du tunnel SSH (10s)..."
sleep 10

if ! kill -0 "$SSH_TUNNEL_PID" 2>/dev/null; then
  error "Le tunnel SSH ne s'est pas établi correctement."
  exit 1
fi
success "Tunnel SSH actif — Flask accessible sur port $FLASK_PORT"

# Vérification Flask accessible
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "$FLASK_URL/health" --max-time 5 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
  success "Flask répond : HTTP 200"
elif [ "$HTTP_CODE" = "000" ]; then
  warn "Flask ne répond pas — cloud-init peut encore être en cours."
  read -p "  Continuer quand même ? (o/n) : " CONTINUE
  if [ "$CONTINUE" != "o" ] && [ "$CONTINUE" != "O" ]; then exit 0; fi
else
  warn "Flask répond HTTP $HTTP_CODE"
  read -p "  Continuer quand même ? (o/n) : " CONTINUE
  if [ "$CONTINUE" != "o" ] && [ "$CONTINUE" != "O" ]; then exit 0; fi
fi

# ==============================================================================
# PHASE 5 : GÉNÉRATION DU TRAFIC
# ==============================================================================

separator "PHASE 5 : Génération du trafic"

info "Démarrage de $ITERATIONS cycles de trafic..."
echo ""

TOTAL_REQUESTS=0

for i in $(seq 1 "$ITERATIONS"); do
  echo "  --- Cycle $i / $ITERATIONS ---"

  call_endpoint "GET" "/health" "" \
    "Health check"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  call_endpoint "POST" "/send" \
    "{\"order_id\": \"order-${ENV}-${i}\", \"product\": \"item-$i\", \"quantity\": $i}" \
    "Envoi queue orders"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  call_endpoint "GET" "/receive" "" \
    "Réception queue orders"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  call_endpoint "POST" "/publish" \
    "{\"event\": \"order-processed\", \"level\": \"info\", \"order_id\": \"order-${ENV}-${i}\"}" \
    "Publication topic events (info)"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  # Un message critical tous les 3 cycles pour déclencher sub-alerts
  if [ $((i % 3)) -eq 0 ]; then
    call_endpoint "POST" "/publish" \
      "{\"event\": \"payment-failed\", \"level\": \"critical\", \"order_id\": \"order-${ENV}-${i}\"}" \
      "Publication topic events (critical)"
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
  fi

  call_endpoint "GET" "/subscribe/sub-logs" "" \
    "Lecture sub-logs"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  call_endpoint "GET" "/subscribe/sub-alerts" "" \
    "Lecture sub-alerts"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  call_endpoint "POST" "/metrics/emit" \
    "{\"metric_name\": \"orders_processed\", \"value\": $i, \"tags\": {\"env\": \"$ENV\"}}" \
    "Envoi métriques Event Hub"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  # Lecture DLQ une fois sur deux
  if [ $((i % 2)) -eq 0 ]; then
    call_endpoint "GET" "/dlq" "" \
      "Lecture dead-letter queue"
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
  fi

  echo ""
  sleep 2
done

# ==============================================================================
# RÉSULTAT
# ==============================================================================

separator "TRAFIC GÉNÉRÉ"

echo "  Cycles effectués  : $ITERATIONS"
echo "  Requêtes envoyées : $TOTAL_REQUESTS"
echo ""
echo "  Les métriques sont visibles dans Grafana."
echo "  Pour accéder à Grafana, lancez :"
echo "    ./scripts/setup-monitoring.sh $ENV"
echo ""
echo "  Ou ouvrez manuellement un tunnel vers la VM Monitoring :"
echo ""
echo "  az network bastion tunnel \\"
echo "    --name $BASTION_NAME \\"
echo "    --resource-group $RESOURCE_GROUP \\"
echo "    --target-resource-id <vm-monitoring-id> \\"
echo "    --resource-port 22 \\"
echo "    --port 2222"
echo ""
echo "  Puis dans un autre terminal :"
echo "  ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \\"
echo "    -L 3000:localhost:3000 \\"
echo "    -L 9090:localhost:9090 \\"
echo "    -L 9091:localhost:9091"
echo ""
echo "  Grafana     : http://localhost:3000"
echo "  Prometheus  : http://localhost:9090"
echo "  Pushgateway : http://localhost:9091"
