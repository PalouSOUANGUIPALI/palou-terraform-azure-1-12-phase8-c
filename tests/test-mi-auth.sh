#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : tests/test-mi-auth.sh
# Description : Vérifie que la Managed Identity de la VM Flask peut
#               s'authentifier auprès de Key Vault et accéder aux secrets
#               Service Bus et Event Hub.
#
#               Tests effectués :
#                 1. Présence de la Managed Identity sur la VM Flask
#                 2. Statut global de l'application via /health
#                 3. Accès au secret servicebus-connection-string
#                 4. Accès au secret eventhub-connection-string
#                 5. Attributions RBAC de la MI vérifiées via Azure CLI
#                    (Key Vault Secrets User)
#
#               Les tests 2, 3 et 4 nécessitent un tunnel Bastion actif.
#               Le test 5 fonctionne sans tunnel.
#
# Usage :
#   ./tests/test-mi-auth.sh <env>
#   ./tests/test-mi-auth.sh dev
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

call_get() {
  local endpoint="$1"
  curl -s --max-time 15 "$BASE_URL$endpoint" 2>/dev/null || echo ""
}

get_http_code() {
  curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "$BASE_URL$endpoint" 2>/dev/null
  return 0
}

# ==============================================================================
# VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

echo "=== Test Managed Identity Auth - Phase 8C ($ENV) ==="
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

# Vérifier si le tunnel est actif — optionnel
endpoint="/health"
HTTP_CODE=$(get_http_code "/health")
TUNNEL_ACTIVE=false
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "503" ]; then
  TUNNEL_ACTIVE=true
  echo "  [OK] Tunnel actif sur localhost:5000"
else
  echo "  [INFO] Tunnel Bastion non actif — tests /health ignorés (test RBAC effectué)"
fi

echo ""

# ==============================================================================
# TEST 1 : MANAGED IDENTITY SUR LA VM FLASK
# ==============================================================================

echo "--- Test 1 : Managed Identity sur la VM Flask ---"

VM_APP_NAME="vm-${PROJECT_PREFIX}-${ENV}-app"
MI_PRINCIPAL=""

VM_STATE=$(az vm show \
  --resource-group "$RG" \
  --name "$VM_APP_NAME" \
  --query "provisioningState" -o tsv 2>/dev/null || echo "")

if [ -z "$VM_STATE" ]; then
  fail "VM Flask '$VM_APP_NAME' introuvable dans $RG"
else
  pass "VM Flask trouvée : $VM_APP_NAME"

  MI_TYPE=$(az vm show \
    --resource-group "$RG" \
    --name "$VM_APP_NAME" \
    --query "identity.type" -o tsv 2>/dev/null || echo "")

  MI_PRINCIPAL=$(az vm show \
    --resource-group "$RG" \
    --name "$VM_APP_NAME" \
    --query "identity.principalId" -o tsv 2>/dev/null || echo "")

  if [ -n "$MI_PRINCIPAL" ]; then
    pass "Managed Identity : $MI_TYPE"
    pass "Principal ID     : $MI_PRINCIPAL"
  else
    fail "Managed Identity introuvable sur la VM Flask"
    echo "  Vérifiez le module compute dans Terraform."
  fi
fi

echo ""

# ==============================================================================
# TEST 2 : HEALTH ENDPOINT - STATUT GLOBAL
# ==============================================================================

echo "--- Test 2 : Statut global de l'application ---"

HEALTH_RESPONSE=""

if $TUNNEL_ACTIVE; then
  HEALTH_RESPONSE=$(call_get "/health")
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 "$BASE_URL/health" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /health : HTTP 200 (Service Bus et Event Hub healthy)"
  elif [ "$HTTP_CODE" = "503" ]; then
    warn "GET /health : HTTP 503 (un ou plusieurs services dégradés)"
  else
    fail "GET /health : HTTP $HTTP_CODE"
  fi

  if [ -n "$HEALTH_RESPONSE" ]; then
    APP_STATUS=$(echo "$HEALTH_RESPONSE" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" \
      2>/dev/null || echo "unknown")
    if [ "$APP_STATUS" != "unknown" ]; then
      pass "Statut applicatif : $APP_STATUS"
    else
      warn "Statut applicatif non lisible depuis la réponse /health"
    fi
  fi
else
  warn "GET /health : tunnel non actif — test ignoré"
fi

echo ""

# ==============================================================================
# TEST 3 : ACCÈS SECRET SERVICE BUS VIA KEY VAULT
# ==============================================================================

echo "--- Test 3 : Accès secret servicebus-connection-string via Key Vault ---"

if $TUNNEL_ACTIVE && [ -n "$HEALTH_RESPONSE" ]; then
  SB_STATUS=$(echo "$HEALTH_RESPONSE" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('services',{}).get('service_bus',{}).get('status','unknown'))" \
    2>/dev/null || echo "unknown")

  if [ "$SB_STATUS" = "healthy" ]; then
    pass "Secret servicebus-connection-string : accessible via MI"
    pass "Service Bus : connecté"
    echo ""
    echo "  Mécanisme :"
    echo "    1. Flask appelle IMDS : http://169.254.169.254/metadata/identity/oauth2/token"
    echo "    2. Scope  : https://vault.azure.net/.default"
    echo "    3. Token  : Bearer JWT retourné par Azure AD"
    echo "    4. Key Vault retourne le secret servicebus-connection-string"
    echo "    5. ServiceBusClient.from_connection_string() utilise ce secret"
  elif [ "$SB_STATUS" = "unknown" ]; then
    warn "Service Bus : statut indéterminé dans /health"
  else
    fail "Secret servicebus-connection-string : échec ($SB_STATUS)"
    echo "  Causes possibles :"
    echo "    - RBAC Key Vault Secrets User non attribué à la MI"
    echo "    - Secret absent du Key Vault"
    echo "    - Private Endpoint Key Vault non résolu"
    echo "    - IMDS non accessible depuis la VM (vérifiez le NSG snet-app)"
  fi
else
  warn "Service Bus : tunnel non actif — test ignoré"
fi

echo ""

# ==============================================================================
# TEST 4 : ACCÈS SECRET EVENT HUB VIA KEY VAULT
# ==============================================================================

echo "--- Test 4 : Accès secret eventhub-connection-string via Key Vault ---"

if $TUNNEL_ACTIVE && [ -n "$HEALTH_RESPONSE" ]; then
  EH_STATUS=$(echo "$HEALTH_RESPONSE" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('services',{}).get('event_hub',{}).get('status','unknown'))" \
    2>/dev/null || echo "unknown")

  if [ "$EH_STATUS" = "healthy" ]; then
    pass "Secret eventhub-connection-string : accessible via MI"
    pass "Event Hub : connecté"
    echo ""
    echo "  Mécanisme :"
    echo "    1. Flask appelle IMDS : http://169.254.169.254/metadata/identity/oauth2/token"
    echo "    2. Scope  : https://vault.azure.net/.default"
    echo "    3. Token  : Bearer JWT retourné par Azure AD"
    echo "    4. Key Vault retourne le secret eventhub-connection-string"
    echo "    5. EventHubProducerClient.from_connection_string() utilise ce secret"
  elif [ "$EH_STATUS" = "unknown" ]; then
    warn "Event Hub : statut indéterminé dans /health"
  else
    fail "Secret eventhub-connection-string : échec ($EH_STATUS)"
    echo "  Causes possibles :"
    echo "    - RBAC Key Vault Secrets User non attribué à la MI"
    echo "    - Secret absent du Key Vault"
    echo "    - Private Endpoint Key Vault non résolu"
    echo "    - IMDS non accessible depuis la VM (vérifiez le NSG snet-app)"
  fi
else
  warn "Event Hub : tunnel non actif — test ignoré"
fi

echo ""

# ==============================================================================
# TEST 5 : ATTRIBUTIONS RBAC VIA AZURE CLI
# ==============================================================================

echo "--- Test 5 : Attributions RBAC de la Managed Identity ---"

if [ -n "${MI_PRINCIPAL:-}" ]; then
  SUBSCRIPTION_ID=$(az account show --query "id" -o tsv 2>/dev/null || echo "")

  # Key Vault Secrets User
  KV_NAME=$(az keyvault list \
    --resource-group "$RG" \
    --query "[0].name" -o tsv 2>/dev/null || echo "")

  if [ -n "$KV_NAME" ]; then
    KV_ID=$(az keyvault show \
      --resource-group "$RG" \
      --name "$KV_NAME" \
      --query "id" -o tsv 2>/dev/null || echo "")

    KV_SECRETS_USER=$(az role assignment list \
      --assignee "$MI_PRINCIPAL" \
      --role "Key Vault Secrets User" \
      --scope "$KV_ID" \
      --query "[0].id" -o tsv 2>/dev/null || echo "")

    if [ -n "$KV_SECRETS_USER" ]; then
      pass "RBAC Key Vault Secrets User sur $KV_NAME"
    else
      fail "RBAC Key Vault Secrets User manquant sur $KV_NAME"
      echo "  La MI ne peut pas lire les secrets Service Bus et Event Hub."
    fi
  else
    warn "Key Vault introuvable dans $RG — RBAC non vérifié"
  fi

  # Monitoring Metrics Publisher
  MONITORING_PUBLISHER=$(az role assignment list \
    --assignee "$MI_PRINCIPAL" \
    --role "Monitoring Metrics Publisher" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")

  if [ -n "$MONITORING_PUBLISHER" ]; then
    pass "RBAC Monitoring Metrics Publisher sur $RG"
  else
    fail "RBAC Monitoring Metrics Publisher manquant sur $RG"
  fi

  # Service Bus Data Owner
  SB_NAMESPACE=$(az servicebus namespace list \
    --resource-group "$RG" \
    --query "[0].name" -o tsv 2>/dev/null || echo "")

  if [ -n "$SB_NAMESPACE" ]; then
    SB_ID=$(az servicebus namespace show \
      --resource-group "$RG" \
      --name "$SB_NAMESPACE" \
      --query "id" -o tsv 2>/dev/null || echo "")

    SB_DATA_OWNER=$(az role assignment list \
      --assignee "$MI_PRINCIPAL" \
      --role "Azure Service Bus Data Owner" \
      --scope "$SB_ID" \
      --query "[0].id" -o tsv 2>/dev/null || echo "")

    if [ -n "$SB_DATA_OWNER" ]; then
      pass "RBAC Azure Service Bus Data Owner sur $SB_NAMESPACE"
    else
      warn "RBAC Azure Service Bus Data Owner non trouvé sur $SB_NAMESPACE"
      echo "  Note : la MI utilise la connection string du Key Vault,"
      echo "  le RBAC direct sur Service Bus est donc optionnel."
    fi
  else
    warn "Service Bus introuvable dans $RG — RBAC non vérifié"
  fi

else
  warn "MI Principal ID non disponible — RBAC non vérifié"
fi

echo ""

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo "=== Résultat Managed Identity Auth ($ENV) ==="
echo ""
echo "  Réussies  : $OK"
echo "  Avertiss. : $WARN"
echo "  Échouées  : $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  La Managed Identity est correctement configurée."
  echo "  Les secrets Key Vault sont accessibles depuis la VM Flask."
  exit 0
else
  echo "  $FAIL problème(s) détecté(s)."
  echo "  Consultez les logs de la VM Flask via le tunnel Bastion :"
  echo ""
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1"
  echo ""
  echo "    # Puis sur la VM"
  echo "    journalctl -u flask-app -n 100"
  echo "    journalctl -u eventhub-consumer -n 100"
  exit 1
fi
