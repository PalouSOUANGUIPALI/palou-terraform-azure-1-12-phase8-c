#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : validate.sh
# Description : Vérifie que l'infrastructure d'un environnement est
#               correctement déployée :
#                 - Resource Group et réseau (VNet, subnets, NSGs)
#                 - Azure Bastion
#                 - VM Flask (vm-app) et VM Monitoring (vm-monitoring)
#                 - Service Bus Namespace (queues, topics, abonnements)
#                 - Event Hub Namespace (hub app-metrics, consumer groups)
#                 - Key Vault (secrets, RBAC)
#                 - Private Endpoints et zones DNS privées
#                 - Log Analytics Workspace
#
#               La connectivité applicative (Service Bus et Event Hub
#               depuis la VM Flask) ne peut être vérifiée qu'en se
#               connectant via Bastion et en testant /health.
#
# Prérequis :
#   - Azure CLI installé et connecté (az login)
#
# Usage :
#   ./scripts/validate.sh <env>
#   ./scripts/validate.sh dev
#   ./scripts/validate.sh staging
#   ./scripts/validate.sh prod
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

if ! command -v az &> /dev/null; then
  echo "ERREUR : Azure CLI non installé."
  exit 1
fi

if ! az account show &> /dev/null 2>&1; then
  echo "ERREUR : Non connecté à Azure. Exécutez : az login"
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "=== Validation de l'environnement $(echo "$ENV" | tr '[:lower:]' '[:upper:]') ==="
echo ""

# ==============================================================================
# SECTION 1 : RESOURCE GROUP
# ==============================================================================

echo "--- Resource Group ---"

if az group show --name "$RG" &> /dev/null 2>&1; then
  RG_LOCATION=$(az group show --name "$RG" --query "location" -o tsv)
  pass "Resource Group $RG ($RG_LOCATION)"
else
  fail "Resource Group $RG introuvable"
  echo ""
  echo "  Le déploiement $ENV n'a pas encore été effectué."
  echo "  Exécutez : ./scripts/deploy-${ENV}.sh"
  echo ""
  echo "=== Résultat ==="
  echo "  Réussies  : $OK"
  echo "  Avertiss. : $WARN"
  echo "  Échouées  : $FAIL"
  exit 1
fi

echo ""

# ==============================================================================
# SECTION 2 : RÉSEAU
# ==============================================================================

echo "--- Réseau ---"

VNET_NAME=$(az network vnet list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -n "$VNET_NAME" ]; then
  VNET_PREFIX=$(az network vnet show \
    --resource-group "$RG" \
    --name "$VNET_NAME" \
    --query "addressSpace.addressPrefixes[0]" -o tsv 2>/dev/null || echo "")
  pass "VNet $VNET_NAME ($VNET_PREFIX)"
else
  fail "VNet introuvable dans $RG"
  VNET_NAME=""
fi

if [ -n "$VNET_NAME" ]; then
  for SUBNET in "AzureBastionSubnet" "snet-app" "snet-monitoring" "snet-pe"; do
    SUBNET_PREFIX=$(az network vnet subnet show \
      --resource-group "$RG" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET" \
      --query "addressPrefix" -o tsv 2>/dev/null || echo "")

    if [ -n "$SUBNET_PREFIX" ]; then
      pass "Subnet $SUBNET ($SUBNET_PREFIX)"
    else
      fail "Subnet $SUBNET introuvable"
    fi
  done
fi

echo ""

# ==============================================================================
# SECTION 3 : AZURE BASTION
# ==============================================================================

echo "--- Azure Bastion ---"

BASTION_NAME="bastion-${PROJECT_PREFIX}-${ENV}"
BASTION_STATE=$(az network bastion show \
  --resource-group "$RG" \
  --name "$BASTION_NAME" \
  --query "provisioningState" -o tsv 2>/dev/null || echo "")

if [ "$BASTION_STATE" = "Succeeded" ]; then
  pass "Azure Bastion $BASTION_NAME : actif"
else
  fail "Azure Bastion $BASTION_NAME : ${BASTION_STATE:-introuvable}"
fi

BASTION_SKU=$(az network bastion show \
  --resource-group "$RG" \
  --name "$BASTION_NAME" \
  --query "sku.name" -o tsv 2>/dev/null || echo "")

if [ "$BASTION_SKU" = "Standard" ] || [ "$BASTION_SKU" = "Premium" ]; then
  pass "Azure Bastion SKU : $BASTION_SKU (tunnels activés)"
else
  warn "Azure Bastion SKU : ${BASTION_SKU:-inconnu} (tunnels non disponibles)"
fi

echo ""

# ==============================================================================
# SECTION 4 : VMs
# ==============================================================================

echo "--- VMs ---"

VM_APP_NAME="vm-${PROJECT_PREFIX}-${ENV}-app"
VM_APP_ID=""
VM_MONITORING_NAME="vm-${PROJECT_PREFIX}-${ENV}-monitoring"
VM_MONITORING_ID=""

for VM_NAME in "$VM_APP_NAME" "$VM_MONITORING_NAME"; do
  VM_STATE=$(az vm show \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "")

  if [ "$VM_STATE" = "Succeeded" ]; then
    pass "VM $VM_NAME : provisionnée"
  else
    fail "VM $VM_NAME : ${VM_STATE:-introuvable}"
    continue
  fi

  VM_RUNNING=$(az vm get-instance-view \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --query "instanceView.statuses[?code=='PowerState/running'].code" \
    -o tsv 2>/dev/null || echo "")

  if [ -n "$VM_RUNNING" ]; then
    pass "VM $VM_NAME : en cours d'exécution"
  else
    fail "VM $VM_NAME : non démarrée"
  fi

  VM_IP=$(az vm show \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --show-details \
    --query "privateIps" -o tsv 2>/dev/null || echo "")

  if [ -n "$VM_IP" ]; then
    pass "VM $VM_NAME IP privée : $VM_IP"
  else
    warn "IP privée introuvable pour $VM_NAME"
  fi

  MI_PRINCIPAL=$(az vm show \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --query "identity.principalId" -o tsv 2>/dev/null || echo "")

  if [ -n "$MI_PRINCIPAL" ]; then
    pass "VM $VM_NAME Managed Identity : $MI_PRINCIPAL"
  else
    fail "Managed Identity introuvable sur $VM_NAME"
  fi

  # Stocker les IDs pour les commandes de connexion affichées plus bas
  if [ "$VM_NAME" = "$VM_APP_NAME" ]; then
    VM_APP_ID=$(az vm show \
      --resource-group "$RG" \
      --name "$VM_NAME" \
      --query "id" -o tsv 2>/dev/null || echo "")
  else
    VM_MONITORING_ID=$(az vm show \
      --resource-group "$RG" \
      --name "$VM_NAME" \
      --query "id" -o tsv 2>/dev/null || echo "")
  fi
done

echo ""

# ==============================================================================
# SECTION 5 : SERVICE BUS
# ==============================================================================

echo "--- Service Bus ---"

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
    pass "Service Bus Namespace $SB_NAME : actif"
  else
    fail "Service Bus Namespace $SB_NAME : $SB_STATE"
  fi

  SB_SKU=$(az servicebus namespace show \
    --resource-group "$RG" \
    --name "$SB_NAME" \
    --query "sku.name" -o tsv 2>/dev/null || echo "")
  pass "Service Bus SKU : $SB_SKU"

  SB_PUBLIC=$(az servicebus namespace show \
    --resource-group "$RG" \
    --name "$SB_NAME" \
    --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "")

  if [ "$SB_PUBLIC" = "Disabled" ]; then
    pass "Service Bus accès public : désactivé (zero-trust)"
  else
    warn "Service Bus accès public : $SB_PUBLIC"
  fi

  # Queue orders
  QUEUE_STATE=$(az servicebus queue show \
    --resource-group "$RG" \
    --namespace-name "$SB_NAME" \
    --name "orders" \
    --query "status" -o tsv 2>/dev/null || echo "")

  if [ "$QUEUE_STATE" = "Active" ]; then
    pass "Queue orders : Active"
  else
    fail "Queue orders : ${QUEUE_STATE:-introuvable}"
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
# SECTION 6 : EVENT HUB
# ==============================================================================

echo "--- Event Hub ---"

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
    pass "Event Hub Namespace $EH_NAMESPACE : actif"
  else
    fail "Event Hub Namespace $EH_NAMESPACE : $EH_STATE"
  fi

  EH_SKU=$(az eventhubs namespace show \
    --resource-group "$RG" \
    --name "$EH_NAMESPACE" \
    --query "sku.name" -o tsv 2>/dev/null || echo "")
  pass "Event Hub SKU : $EH_SKU"

  EH_PUBLIC=$(az eventhubs namespace show \
    --resource-group "$RG" \
    --name "$EH_NAMESPACE" \
    --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "")

  if [ "$EH_PUBLIC" = "Disabled" ]; then
    pass "Event Hub accès public : désactivé (zero-trust)"
  else
    warn "Event Hub accès public : $EH_PUBLIC"
  fi

  # Event Hub app-metrics
  HUB_STATE=$(az eventhubs eventhub show \
    --resource-group "$RG" \
    --namespace-name "$EH_NAMESPACE" \
    --name "app-metrics" \
    --query "status" -o tsv 2>/dev/null || echo "")

  if [ "$HUB_STATE" = "Active" ]; then
    pass "Event Hub app-metrics : Active"
  else
    fail "Event Hub app-metrics : ${HUB_STATE:-introuvable}"
  fi

  # Consumer group grafana
  CG_STATE=$(az eventhubs eventhub consumer-group show \
    --resource-group "$RG" \
    --namespace-name "$EH_NAMESPACE" \
    --eventhub-name "app-metrics" \
    --name "grafana" \
    --query "name" -o tsv 2>/dev/null || echo "")

  if [ -n "$CG_STATE" ]; then
    pass "Consumer group grafana : présent"
  else
    fail "Consumer group grafana : introuvable"
  fi
fi

echo ""

# ==============================================================================
# SECTION 7 : KEY VAULT
# ==============================================================================

echo "--- Key Vault ---"

KV_NAME=$(az keyvault list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -z "$KV_NAME" ]; then
  fail "Key Vault introuvable dans $RG"
else
  KV_STATE=$(az keyvault show \
    --resource-group "$RG" \
    --name "$KV_NAME" \
    --query "properties.provisioningState" -o tsv 2>/dev/null || echo "")

  if [ "$KV_STATE" = "Succeeded" ]; then
    pass "Key Vault $KV_NAME : actif"
  else
    fail "Key Vault $KV_NAME : $KV_STATE"
  fi

  KV_RBAC=$(az keyvault show \
    --resource-group "$RG" \
    --name "$KV_NAME" \
    --query "properties.enableRbacAuthorization" -o tsv 2>/dev/null || echo "")

  if [ "$KV_RBAC" = "true" ]; then
    pass "Key Vault RBAC : activé"
  else
    warn "Key Vault RBAC : désactivé"
  fi

  # Secrets
  for SECRET in "servicebus-connection-string" "eventhub-connection-string"; do
    SECRET_ENABLED=$(az keyvault secret show \
      --vault-name "$KV_NAME" \
      --name "$SECRET" \
      --query "attributes.enabled" -o tsv 2>/dev/null || echo "")

    if [ "$SECRET_ENABLED" = "true" ]; then
      pass "Secret $SECRET : présent"
    else
      fail "Secret $SECRET : introuvable ou désactivé"
    fi
  done
fi

echo ""

# ==============================================================================
# SECTION 8 : PRIVATE ENDPOINTS ET DNS
# ==============================================================================

echo "--- Private Endpoints et DNS privés ---"

PE_COUNT=$(az network private-endpoint list \
  --resource-group "$RG" \
  --query "length(@)" -o tsv 2>/dev/null || echo "0")

if [ "$PE_COUNT" -gt 0 ]; then
  pass "Private Endpoints : $PE_COUNT trouvés"

  # Vérification état de chaque PE
  az network private-endpoint list \
    --resource-group "$RG" \
    --query "[].{name:name, state:provisioningState}" -o tsv 2>/dev/null \
  | while IFS=$'\t' read -r PE_NAME PE_STATE; do
      if [ "$PE_STATE" = "Succeeded" ]; then
        pass "Private Endpoint $PE_NAME : actif"
      else
        fail "Private Endpoint $PE_NAME : $PE_STATE"
      fi
    done
else
  fail "Aucun Private Endpoint trouvé dans $RG"
fi

# Zones DNS privées
for DNS_ZONE in \
  "privatelink.servicebus.windows.net" \
  "privatelink.vaultcore.azure.net"; do

  ZONE_EXISTS=$(az network private-dns zone show \
    --resource-group "$RG" \
    --name "$DNS_ZONE" \
    --query "name" -o tsv 2>/dev/null || echo "")

  if [ -n "$ZONE_EXISTS" ]; then
    pass "Zone DNS privée : $DNS_ZONE"
  else
    fail "Zone DNS privée introuvable : $DNS_ZONE"
  fi
done

echo ""

# ==============================================================================
# SECTION 9 : LOG ANALYTICS WORKSPACE
# ==============================================================================

echo "--- Log Analytics Workspace ---"

LAW_NAME=$(az monitor log-analytics workspace list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -n "$LAW_NAME" ]; then
  LAW_STATE=$(az monitor log-analytics workspace show \
    --resource-group "$RG" \
    --workspace-name "$LAW_NAME" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "")

  if [ "$LAW_STATE" = "Succeeded" ]; then
    pass "Log Analytics Workspace $LAW_NAME : actif"
  else
    fail "Log Analytics Workspace $LAW_NAME : $LAW_STATE"
  fi

  LAW_RETENTION=$(az monitor log-analytics workspace show \
    --resource-group "$RG" \
    --workspace-name "$LAW_NAME" \
    --query "retentionInDays" -o tsv 2>/dev/null || echo "")
  pass "Rétention logs : ${LAW_RETENTION} jours"
else
  fail "Log Analytics Workspace introuvable dans $RG"
  LAW_NAME="law-${PROJECT_PREFIX}-${ENV}"
fi

echo ""

# ==============================================================================
# SECTION 10 : CONNEXION APPLICATIVE ET EXPLORATION
# ==============================================================================

echo "--- Connexion applicative et exploration ---"
echo ""
echo "  ----------------------------------------------------------------"
echo "  Accès à la VM Flask via Bastion (tunnel) :"
echo "  ----------------------------------------------------------------"
echo ""
echo "  Terminal 1 — tunnel Bastion vers VM Flask :"
echo ""
echo "    az network bastion tunnel \\"
echo "      --name $BASTION_NAME \\"
echo "      --resource-group $RG \\"
echo "      --target-resource-id $VM_APP_ID \\"
echo "      --resource-port 22 \\"
echo "      --port 2223"
echo ""
echo "  Terminal 2 — connexion SSH et test de l'application :"
echo ""
echo "    ssh -i ~/.ssh/id_rsa_azure -p 2223 azureuser@127.0.0.1"
echo "    curl http://localhost:5000/health"
echo "    curl -X POST http://localhost:5000/api/messages/send \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"order_id\": \"test-1\", \"product\": \"item\", \"quantity\": 1}'"
echo ""
echo "  ----------------------------------------------------------------"
echo "  Accès à la VM Monitoring via Bastion :"
echo "  ----------------------------------------------------------------"
echo ""
echo "  Terminal 1 — tunnel Bastion vers VM Monitoring :"
echo ""
echo "    az network bastion tunnel \\"
echo "      --name $BASTION_NAME \\"
echo "      --resource-group $RG \\"
echo "      --target-resource-id $VM_MONITORING_ID \\"
echo "      --resource-port 22 \\"
echo "      --port 2222"
echo ""
echo "  Terminal 2 — tunnels SSH vers les services :"
echo ""
echo "    ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \\"
echo "      -L 3000:localhost:3000 \\"
echo "      -L 9090:localhost:9090 \\"
echo "      -L 9091:localhost:9091"
echo ""
echo "  Grafana     : http://localhost:3000"
echo "  Prometheus  : http://localhost:9090"
echo "  Pushgateway : http://localhost:9091"
echo ""
echo "  ----------------------------------------------------------------"
echo "  Exploration Log Analytics — portail Azure → $LAW_NAME → Logs"
echo "  ----------------------------------------------------------------"
echo ""
echo "  Métriques Service Bus :"
echo "    AzureMetrics"
echo "    | where ResourceId contains \"$SB_NAME\""
echo "    | where TimeGenerated > ago(1h)"
echo "    | project TimeGenerated, MetricName, Average, Maximum"
echo "    | order by TimeGenerated desc"
echo ""
echo "  Métriques Event Hub :"
echo "    AzureMetrics"
echo "    | where ResourceId contains \"$EH_NAMESPACE\""
echo "    | where TimeGenerated > ago(1h)"
echo "    | project TimeGenerated, MetricName, Average, Maximum"
echo "    | order by TimeGenerated desc"
echo ""
warn "Connexion applicative : vérification manuelle requise"

echo ""

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo "=== Résultat ==="
echo ""
echo "  Réussies  : $OK"
echo "  Avertiss. : $WARN"
echo "  Échouées  : $FAIL"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "  L'infrastructure $ENV est correctement déployée."
  echo "  Procédez à la validation manuelle de la connexion"
  echo "  applicative via Bastion."
  exit 0
elif [ "$FAIL" -eq 0 ]; then
  echo "  L'infrastructure $ENV est déployée avec des avertissements."
  echo "  Vérifiez les points signalés ci-dessus."
  exit 0
else
  echo "  Des problèmes ont été détectés dans $ENV."
  echo "  Corrigez les erreurs avant de continuer."
  exit 1
fi
