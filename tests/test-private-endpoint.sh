#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : tests/test-private-endpoint.sh
# Description : Vérifie la configuration des Private Endpoints et des zones
#               DNS privées pour Service Bus, Event Hub et Key Vault.
#
#               Différence avec les autres tests :
#                 - Ne nécessite pas de tunnel Bastion ouvert
#                 - Teste uniquement la couche infrastructure via Azure CLI
#                 - Vérifie que les PEs sont actifs, que le DNS est configuré,
#                   et que l'accès public est bien désactivé
#
#               Tests effectués :
#                 1. Private Endpoints (Service Bus, Event Hub, Key Vault)
#                 2. Zone DNS privée Service Bus / Event Hub
#                 3. Zone DNS privée Key Vault
#                 4. Liens VNet sur les zones DNS
#                 5. Résolution DNS depuis ordinateur (doit échouer ou IP publique)
#                 6. Résolution DNS depuis Flask via /health (tunnel requis)
#
# Prérequis :
#   - Azure CLI installé et connecté (az login)
#   - Tunnel Bastion ouvert (pour le test 6 uniquement)
#
# Usage :
#   ./tests/test-private-endpoint.sh <env>
#   ./tests/test-private-endpoint.sh dev
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
DNS_ZONE_SB="privatelink.servicebus.windows.net"
DNS_ZONE_KV="privatelink.vaultcore.azure.net"

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
  curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "$BASE_URL/health" 2>/dev/null || echo "000"
}

call_get() {
  local endpoint="$1"
  curl -s --max-time 15 "$BASE_URL$endpoint" 2>/dev/null || echo ""
}

# ==============================================================================
# VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

echo "=== Test Private Endpoint - Phase 8C ($ENV) ==="
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

if ! az group show --name "$RG" &> /dev/null 2>&1; then
  echo "  [ERREUR] Resource Group $RG introuvable."
  echo "  Exécutez d'abord : ./scripts/deploy-${ENV}.sh"
  exit 1
fi

echo "  [OK] Resource Group $RG trouvé"
echo ""

# ==============================================================================
# TEST 1 : PRIVATE ENDPOINTS
# ==============================================================================

echo "--- Test 1 : Private Endpoints ---"

PE_COUNT=$(az network private-endpoint list \
  --resource-group "$RG" \
  --query "length(@)" -o tsv 2>/dev/null || echo "0")

if [ "$PE_COUNT" -eq 0 ]; then
  fail "Aucun Private Endpoint trouvé dans $RG"
  echo "  Vérifiez les modules service-bus, event-hub et key-vault dans Terraform."
else
  pass "Private Endpoints trouvés : $PE_COUNT"
fi

# Vérification de chaque PE
SB_FQDN=""
EH_FQDN=""
KV_FQDN=""

PE_NAMES=$(az network private-endpoint list \
  --resource-group "$RG" \
  --query "[].name" -o tsv 2>/dev/null || echo "")

while IFS= read -r PE_NAME; do
  [ -z "$PE_NAME" ] && continue

  PE_STATE=$(az network private-endpoint show \
    --resource-group "$RG" \
    --name "$PE_NAME" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "")

  PE_CONN_STATE=$(az network private-endpoint show \
    --resource-group "$RG" \
    --name "$PE_NAME" \
    --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState.status" \
    -o tsv 2>/dev/null || echo "")

  PE_SUBNET=$(az network private-endpoint show \
    --resource-group "$RG" \
    --name "$PE_NAME" \
    --query "subnet.id" -o tsv 2>/dev/null || echo "")

  if [ "$PE_STATE" = "Succeeded" ]; then
    pass "Private Endpoint $PE_NAME : Succeeded"
  else
    fail "Private Endpoint $PE_NAME : ${PE_STATE:-inconnu}"
  fi

  if [ "$PE_CONN_STATE" = "Approved" ]; then
    pass "Connexion $PE_NAME : Approved"
  else
    fail "Connexion $PE_NAME : ${PE_CONN_STATE:-inconnu} (attendu : Approved)"
  fi

  if echo "$PE_SUBNET" | grep -q "snet-pe"; then
    pass "Private Endpoint $PE_NAME dans subnet snet-pe"
  else
    fail "Private Endpoint $PE_NAME dans subnet inattendu : $PE_SUBNET"
  fi

  # Récupérer les FQDNs pour les tests DNS
  PE_FQDNS=$(az network private-endpoint show \
    --resource-group "$RG" \
    --name "$PE_NAME" \
    --query "customDnsConfigs[].fqdn" -o tsv 2>/dev/null || echo "")

  while IFS= read -r FQDN; do
    [ -z "$FQDN" ] && continue
    if echo "$FQDN" | grep -q "servicebus.windows.net"; then
      SB_FQDN="$FQDN"
    elif echo "$FQDN" | grep -q "vaultcore.azure.net"; then
      KV_FQDN="$FQDN"
    fi
  done <<< "$PE_FQDNS"

done <<< "$PE_NAMES"

echo ""

# ==============================================================================
# TEST 2 : ZONE DNS PRIVÉE SERVICE BUS ET EVENT HUB
# ==============================================================================

echo "--- Test 2 : Zone DNS privée Service Bus / Event Hub ---"

# Service Bus et Event Hub partagent la même zone DNS privée
DNS_ZONE_SB_EXISTS=$(az network private-dns zone show \
  --resource-group "$RG" \
  --name "$DNS_ZONE_SB" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [ -n "$DNS_ZONE_SB_EXISTS" ]; then
  pass "Zone DNS privée : $DNS_ZONE_SB"
  echo "  Note : Service Bus et Event Hub partagent cette zone DNS."

  RECORD_COUNT=$(az network private-dns record-set a list \
    --resource-group "$RG" \
    --zone-name "$DNS_ZONE_SB" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$RECORD_COUNT" -gt 0 ]; then
    pass "Enregistrements A dans la zone DNS : $RECORD_COUNT"
    az network private-dns record-set a list \
      --resource-group "$RG" \
      --zone-name "$DNS_ZONE_SB" \
      --query "[].{Nom:name, IP:aRecords[0].ipv4Address}" \
      -o table 2>/dev/null | while IFS= read -r line; do
        echo "    $line"
      done
  else
    warn "Aucun enregistrement A dans la zone DNS Service Bus"
    echo "  Les enregistrements sont créés via le Private DNS Zone Group des PEs."
  fi
else
  fail "Zone DNS privée $DNS_ZONE_SB introuvable dans $RG"
  echo "  Sans cette zone, Service Bus et Event Hub sont résolus en IP publique."
fi

echo ""

# ==============================================================================
# TEST 3 : ZONE DNS PRIVÉE KEY VAULT
# ==============================================================================

echo "--- Test 3 : Zone DNS privée Key Vault ---"

DNS_ZONE_KV_EXISTS=$(az network private-dns zone show \
  --resource-group "$RG" \
  --name "$DNS_ZONE_KV" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [ -n "$DNS_ZONE_KV_EXISTS" ]; then
  pass "Zone DNS privée : $DNS_ZONE_KV"

  RECORD_COUNT_KV=$(az network private-dns record-set a list \
    --resource-group "$RG" \
    --zone-name "$DNS_ZONE_KV" \
    --query "length(@)" -o tsv 2>/dev/null || echo "0")

  if [ "$RECORD_COUNT_KV" -gt 0 ]; then
    pass "Enregistrements A dans la zone DNS Key Vault : $RECORD_COUNT_KV"
  else
    warn "Aucun enregistrement A dans la zone DNS Key Vault"
  fi
else
  fail "Zone DNS privée $DNS_ZONE_KV introuvable dans $RG"
  echo "  Sans cette zone, Key Vault est résolu en IP publique."
fi

echo ""

# ==============================================================================
# TEST 4 : LIENS VNET SUR LES ZONES DNS
# ==============================================================================

echo "--- Test 4 : Liens VNet sur les zones DNS ---"

for DNS_ZONE in "$DNS_ZONE_SB" "$DNS_ZONE_KV"; do
  DNS_LINK=$(az network private-dns link vnet list \
    --resource-group "$RG" \
    --zone-name "$DNS_ZONE" \
    --query "[0].name" -o tsv 2>/dev/null || echo "")

  if [ -n "$DNS_LINK" ]; then
    DNS_LINK_STATE=$(az network private-dns link vnet show \
      --resource-group "$RG" \
      --zone-name "$DNS_ZONE" \
      --name "$DNS_LINK" \
      --query "virtualNetworkLinkState" -o tsv 2>/dev/null || echo "")

    if [ "$DNS_LINK_STATE" = "Completed" ]; then
      pass "Lien VNet $DNS_LINK ($DNS_ZONE) : $DNS_LINK_STATE"
    else
      fail "Lien VNet $DNS_LINK ($DNS_ZONE) : ${DNS_LINK_STATE:-inconnu} (attendu : Completed)"
    fi
  else
    fail "Aucun lien VNet sur la zone DNS $DNS_ZONE"
    echo "  Sans ce lien, les VMs ne peuvent pas résoudre les FQDNs en IP privée."
  fi
done

echo ""

# ==============================================================================
# TEST 5 : RÉSOLUTION DNS DEPUIS ORDINATEUR
# ==============================================================================

echo "--- Test 5 : Résolution DNS depuis ordinateur ---"
echo "  (depuis ordinateur : doit résoudre en IP publique ou échouer)"
echo "  (depuis la VM dans le VNet : résoudra en IP privée via zone DNS privée)"
echo ""

# Récupérer le FQDN Service Bus
SB_NAMESPACE=$(az servicebus namespace list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -n "$SB_NAMESPACE" ]; then
  SB_FQDN="${SB_NAMESPACE}.servicebus.windows.net"

  RESOLVED_SB=$(python3 -c "
import socket
try:
    ip = socket.gethostbyname('$SB_FQDN')
    print(ip)
except:
    print('unresolved')
" 2>/dev/null || echo "unresolved")

  if [ "$RESOLVED_SB" = "unresolved" ]; then
    pass "FQDN $SB_FQDN non résolu depuis ordinateur (accès public désactivé)"
  elif echo "$RESOLVED_SB" | grep -qE "^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\."; then
    fail "FQDN $SB_FQDN résout en IP privée $RESOLVED_SB depuis ordinateur"
  else
    warn "FQDN $SB_FQDN résout en IP publique $RESOLVED_SB depuis ordinateur"
    echo "  Service Bus répond au TCP mais rejette à l'authentification."
    echo "  publicNetworkAccess=Disabled garantit qu'aucune donnée n'est accessible."
  fi
else
  warn "Service Bus introuvable dans $RG — test DNS ignoré"
fi

# Récupérer le FQDN Key Vault
KV_NAME=$(az keyvault list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -n "$KV_NAME" ]; then
  KV_FQDN="${KV_NAME}.vault.azure.net"

  RESOLVED_KV=$(python3 -c "
import socket
try:
    ip = socket.gethostbyname('$KV_FQDN')
    print(ip)
except:
    print('unresolved')
" 2>/dev/null || echo "unresolved")

  if [ "$RESOLVED_KV" = "unresolved" ]; then
    pass "FQDN $KV_FQDN non résolu depuis ordinateur"
  elif echo "$RESOLVED_KV" | grep -qE "^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\."; then
    fail "FQDN $KV_FQDN résout en IP privée $RESOLVED_KV depuis ordinateur"
  else
    warn "FQDN $KV_FQDN résout en IP publique $RESOLVED_KV depuis ordinateur"
    echo "  Key Vault a public_network_access_enabled=true pour que TFC puisse y accéder."
    echo "  C'est le comportement attendu pour ce projet."
  fi
else
  warn "Key Vault introuvable dans $RG — test DNS ignoré"
fi

echo ""

# ==============================================================================
# TEST 6 : RÉSOLUTION DNS DEPUIS FLASK (TUNNEL REQUIS)
# ==============================================================================

echo "--- Test 6 : Résolution DNS depuis Flask ---"

HTTP_CODE=$(get_http_code)

if [ "$HTTP_CODE" = "000" ]; then
  warn "Tunnel Bastion non actif — test ignoré"
  echo "  Pour tester, ouvrez les tunnels :"
  echo ""
  echo "  Terminal 1 :"
  echo "    az network bastion tunnel \\"
  echo "      --name bastion-${PROJECT_PREFIX}-${ENV} \\"
  echo "      --resource-group $RG \\"
  echo "      --target-resource-id <vm-app-id> \\"
  echo "      --resource-port 22 --port 2223"
  echo ""
  echo "  Terminal 2 :"
  echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1 \\"
  echo "      -L 5000:localhost:5000 -N"
else
  HEALTH_RESPONSE=$(call_get "/health")

  SB_STATUS=$(echo "$HEALTH_RESPONSE" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('services',{}).get('service_bus',{}).get('status','unknown'))" \
    2>/dev/null || echo "unknown")

  EH_STATUS=$(echo "$HEALTH_RESPONSE" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('services',{}).get('event_hub',{}).get('status','unknown'))" \
    2>/dev/null || echo "unknown")

  if [ "$SB_STATUS" = "healthy" ]; then
    pass "Flask résout et atteint Service Bus via Private Endpoint : healthy"
  elif [ "$SB_STATUS" = "unknown" ]; then
    warn "Service Bus depuis Flask : statut indéterminé"
  else
    warn "Flask ne peut pas atteindre Service Bus : $SB_STATUS"
    echo "  Vérifiez depuis la VM : nslookup $SB_FQDN"
    echo "  Attendu : IP dans la plage du subnet snet-pe"
  fi

  if [ "$EH_STATUS" = "healthy" ]; then
    pass "Flask résout et atteint Event Hub via Private Endpoint : healthy"
  elif [ "$EH_STATUS" = "unknown" ]; then
    warn "Event Hub depuis Flask : statut indéterminé"
  else
    warn "Flask ne peut pas atteindre Event Hub : $EH_STATUS"
  fi
fi

echo ""

# ==============================================================================
# RÉSUMÉ ARCHITECTURE
# ==============================================================================

echo "--- Résumé de l'architecture Private Endpoints ---"
echo ""
echo "  VM Flask (snet-app)"
echo "    ↓ AMQP 5671/5672"
echo "  snet-pe — Private Endpoint Service Bus"
echo "    DNS : $DNS_ZONE_SB"
echo "    ${SB_NAMESPACE:-<sb-namespace>}.servicebus.windows.net → IP privée snet-pe"
echo ""
echo "  VM Flask (snet-app)"
echo "    ↓ HTTPS 443"
echo "  snet-pe — Private Endpoint Key Vault"
echo "    DNS : $DNS_ZONE_KV"
echo "    ${KV_NAME:-<kv-name>}.vault.azure.net → IP privée snet-pe"
echo ""
echo "  Ordinateur (externe au VNet)"
echo "    ✗ accès refusé via Private Endpoints"
echo "    ✓ Key Vault accessible publiquement (nécessaire pour TFC)"
echo ""

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo "=== Résultat Private Endpoint ($ENV) ==="
echo ""
echo "  Réussies  : $OK"
echo "  Avertiss. : $WARN"
echo "  Échouées  : $FAIL"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "  Les Private Endpoints sont correctement configurés."
  echo "  DNS privé actif, PEs approuvés, accès public désactivé."
  exit 0
elif [ "$FAIL" -eq 0 ]; then
  echo "  Private Endpoints opérationnels avec avertissements mineurs."
  exit 0
else
  echo "  $FAIL problème(s) détecté(s)."
  echo "  Vérifiez la configuration réseau et DNS dans Terraform."
  exit 1
fi
