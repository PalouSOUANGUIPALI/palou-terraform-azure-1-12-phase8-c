#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : setup-monitoring.sh
# Description : Configure la stack monitoring sur la VM Monitoring.
#               1. Vérifie les prérequis (Azure CLI, Bastion)
#               2. Récupère l'IP privée de la VM Monitoring depuis Azure
#               3. Demande le mot de passe Grafana
#               4. Ouvre un tunnel Bastion vers la VM Monitoring
#               5. Copie les fichiers monitoring/ vers /opt/monitoring/
#               6. Lance docker compose up avec GF_ADMIN_PASSWORD
#               7. Ferme le tunnel et libère le port
#
#               Ce script est à relancer après chaque modification des
#               fichiers dans monitoring/ — cloud-init installe Docker
#               et crée les répertoires, mais ne copie pas les fichiers
#               de configuration (séparation des responsabilités).
#
# Prérequis :
#   - Azure CLI installé et connecté (az login)
#   - Bastion Standard déployé dans le même VNet
#   - VM Monitoring déployée (terraform apply terminé)
#   - Clé SSH : ~/.ssh/id_rsa_azure
#
# Usage :
#   ./scripts/setup-monitoring.sh <env>
#   Exemple : ./scripts/setup-monitoring.sh dev
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

ENV="${1:-}"
SSH_KEY="$HOME/.ssh/id_rsa_azure"
SSH_PORT_MONITORING=2222
LOCAL_HOST="127.0.0.1"
REMOTE_MONITORING_DIR="/opt/monitoring"
TUNNEL_PID=""

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

usage() {
  echo ""
  echo "  Usage : ./scripts/setup-monitoring.sh <env>"
  echo "  Environnements valides : dev, staging, prod"
  echo ""
  exit 1
}

# Fermeture propre du tunnel et libération du port
close_tunnel() {
  if [ -n "$TUNNEL_PID" ]; then
    info "Fermeture du tunnel Bastion (PID $TUNNEL_PID)..."
    kill "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
  fi
  # Libération du port au cas où un processus résiduel l'occupe encore
  local pid_on_port
  pid_on_port=$(lsof -ti:"$SSH_PORT_MONITORING" 2>/dev/null || true)
  if [ -n "$pid_on_port" ]; then
    kill "$pid_on_port" 2>/dev/null || true
  fi
  sleep 1
}

# ==============================================================================
# VÉRIFICATION DE L'ARGUMENT
# ==============================================================================

if [ -z "$ENV" ]; then
  error "Environnement non spécifié."
  usage
fi

if [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  error "Environnement invalide : $ENV"
  usage
fi

RESOURCE_GROUP="rg-phase8c-$ENV"
PROJECT_PREFIX="phase8c"

separator "SETUP MONITORING — $ENV"

# ==============================================================================
# PHASE 1 : VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

separator "PHASE 1 : Vérification des prérequis"

PREREQS_OK=true

# Azure CLI
if command -v az &> /dev/null; then
  if az account show &> /dev/null 2>&1; then
    AZ_ACCOUNT=$(az account show --query "name" -o tsv)
    success "Azure CLI : connecté ($AZ_ACCOUNT)"
  else
    error "Azure CLI installé mais non connecté."
    echo "         Exécutez : az login"
    PREREQS_OK=false
  fi
else
  error "Azure CLI non installé."
  echo "         Installation : brew install azure-cli"
  PREREQS_OK=false
fi

# Clé SSH
if [ -f "$SSH_KEY" ]; then
  success "Clé SSH : $SSH_KEY"
else
  error "Clé SSH introuvable : $SSH_KEY"
  echo "         Générez-la avec :"
  echo "         ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure"
  PREREQS_OK=false
fi

# Fichiers monitoring
for FILE in \
  "monitoring/docker-compose.yml" \
  "monitoring/prometheus.yml" \
  "monitoring/grafana/provisioning/datasources/datasource.yml" \
  "monitoring/grafana/provisioning/dashboards/dashboard.yml" \
  "monitoring/grafana/provisioning/dashboards/dashboard-eventhub.json"; do
  if [ -f "$FILE" ]; then
    success "$FILE : OK"
  else
    error "$FILE introuvable"
    PREREQS_OK=false
  fi
done

if [ "$PREREQS_OK" = false ]; then
  echo ""
  error "Des prérequis manquent. Corrigez les erreurs ci-dessus."
  exit 1
fi

echo ""
success "Tous les prérequis sont satisfaits."

# ==============================================================================
# PHASE 2 : RÉCUPÉRATION DES RESSOURCES AZURE
# ==============================================================================

separator "PHASE 2 : Récupération des ressources Azure"

# Resource Group
if az group show --name "$RESOURCE_GROUP" &> /dev/null 2>&1; then
  success "Resource Group : $RESOURCE_GROUP"
else
  error "Resource Group '$RESOURCE_GROUP' introuvable."
  echo "         Vérifiez que le déploiement Terraform est terminé."
  exit 1
fi

# VM Monitoring
VM_MONITORING_NAME="vm-${PROJECT_PREFIX}-${ENV}-monitoring"
VM_MONITORING_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_MONITORING_NAME" \
  --query "id" -o tsv 2>/dev/null || echo "")

if [ -z "$VM_MONITORING_ID" ]; then
  error "VM Monitoring '$VM_MONITORING_NAME' introuvable."
  exit 1
fi
success "VM Monitoring : $VM_MONITORING_NAME"

# IP privée VM Monitoring
VM_MONITORING_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_MONITORING_NAME" \
  --show-details \
  --query "privateIps" -o tsv 2>/dev/null || echo "")

if [ -z "$VM_MONITORING_IP" ]; then
  error "IP privée de la VM Monitoring introuvable."
  exit 1
fi
success "IP privée VM Monitoring : $VM_MONITORING_IP"

# Bastion
BASTION_NAME="bastion-${PROJECT_PREFIX}-${ENV}"
BASTION_ID=$(az network bastion show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BASTION_NAME" \
  --query "id" -o tsv 2>/dev/null || echo "")

if [ -z "$BASTION_ID" ]; then
  error "Bastion '$BASTION_NAME' introuvable."
  exit 1
fi
success "Bastion : $BASTION_NAME"

# ==============================================================================
# PHASE 3 : MOT DE PASSE GRAFANA
# ==============================================================================

separator "PHASE 3 : Mot de passe Grafana"

echo "  Le mot de passe Grafana sera injecté comme variable d'environnement"
echo "  avant docker compose up — jamais écrit en clair dans un fichier."
echo ""

while true; do
  read -s -p "  Mot de passe Grafana admin : " GF_ADMIN_PASSWORD
  echo ""
  read -s -p "  Confirmation               : " GF_ADMIN_PASSWORD_CONFIRM
  echo ""
  if [ "$GF_ADMIN_PASSWORD" = "$GF_ADMIN_PASSWORD_CONFIRM" ]; then
    if [ -z "$GF_ADMIN_PASSWORD" ]; then
      error "Le mot de passe ne peut pas être vide."
    else
      success "Mot de passe Grafana défini."
      break
    fi
  else
    error "Les mots de passe ne correspondent pas. Réessayez."
  fi
done

# ==============================================================================
# PHASE 4 : TUNNEL BASTION
# ==============================================================================

separator "PHASE 4 : Ouverture du tunnel Bastion"

# Libération du port si déjà occupé
if lsof -ti:"$SSH_PORT_MONITORING" &> /dev/null; then
  info "Port $SSH_PORT_MONITORING déjà utilisé — libération..."
  kill "$(lsof -ti:"$SSH_PORT_MONITORING")" 2>/dev/null || true
  sleep 2
fi

info "Ouverture du tunnel Bastion vers $VM_MONITORING_IP:22 sur port local $SSH_PORT_MONITORING..."

az network bastion tunnel \
  --name "$BASTION_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --target-resource-id "$VM_MONITORING_ID" \
  --resource-port 22 \
  --port "$SSH_PORT_MONITORING" &

TUNNEL_PID=$!
info "Tunnel PID : $TUNNEL_PID"
info "Attente de l'établissement du tunnel (15s)..."
sleep 15

# Vérification du tunnel
if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
  error "Le tunnel Bastion ne s'est pas établi correctement."
  close_tunnel
  exit 1
fi
success "Tunnel Bastion actif sur port $SSH_PORT_MONITORING"

# ==============================================================================
# PHASE 5 : COPIE DES FICHIERS MONITORING
# ==============================================================================

separator "PHASE 5 : Copie des fichiers monitoring"

# Options SSH — port en minuscule -p pour ssh
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -p $SSH_PORT_MONITORING"

# Options SCP — port en majuscule -P pour scp
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY -P $SSH_PORT_MONITORING"

# Fonction de copie scp via tunnel
scp_to_vm() {
  local src="$1"
  local dst="$2"
  scp $SCP_OPTS "$src" "azureuser@$LOCAL_HOST:$dst"
}

# Fonction ssh via tunnel
ssh_vm() {
  ssh $SSH_OPTS "azureuser@$LOCAL_HOST" "$@"
}

# Création des répertoires (au cas où cloud-init n'est pas encore terminé)
info "Vérification des répertoires sur la VM..."
ssh_vm "sudo mkdir -p $REMOTE_MONITORING_DIR/grafana/provisioning/datasources \
  $REMOTE_MONITORING_DIR/grafana/provisioning/dashboards \
  $REMOTE_MONITORING_DIR/prometheus/rules \
  && sudo chown -R azureuser:azureuser $REMOTE_MONITORING_DIR"
success "Répertoires prêts"

info "Copie docker-compose.yml..."
scp_to_vm "monitoring/docker-compose.yml" "$REMOTE_MONITORING_DIR/docker-compose.yml"
success "docker-compose.yml copié"

info "Copie prometheus.yml..."
scp_to_vm "monitoring/prometheus.yml" "$REMOTE_MONITORING_DIR/prometheus.yml"
success "prometheus.yml copié"

info "Copie datasource.yml..."
scp_to_vm "monitoring/grafana/provisioning/datasources/datasource.yml" \
  "$REMOTE_MONITORING_DIR/grafana/provisioning/datasources/datasource.yml"
success "datasource.yml copié"

info "Copie dashboard.yml..."
scp_to_vm "monitoring/grafana/provisioning/dashboards/dashboard.yml" \
  "$REMOTE_MONITORING_DIR/grafana/provisioning/dashboards/dashboard.yml"
success "dashboard.yml copié"

info "Copie dashboard-eventhub.json..."
scp_to_vm "monitoring/grafana/provisioning/dashboards/dashboard-eventhub.json" \
  "$REMOTE_MONITORING_DIR/grafana/provisioning/dashboards/dashboard-eventhub.json"
success "dashboard-eventhub.json copié"

# ==============================================================================
# PHASE 6 : DÉMARRAGE DE LA STACK
# ==============================================================================

separator "PHASE 6 : Démarrage de la stack monitoring"

info "Arrêt de la stack existante si active..."
ssh_vm "cd $REMOTE_MONITORING_DIR && docker compose down 2>/dev/null || true"

info "Démarrage de la stack avec GF_ADMIN_PASSWORD..."
ssh_vm "cd $REMOTE_MONITORING_DIR \
  && GF_ADMIN_PASSWORD='$GF_ADMIN_PASSWORD' docker compose up -d"

info "Attente du démarrage des conteneurs (15s)..."
sleep 15

info "Statut des conteneurs :"
ssh_vm "cd $REMOTE_MONITORING_DIR && docker compose ps"

# ==============================================================================
# PHASE 7 : FERMETURE DU TUNNEL ET LIBÉRATION DU PORT
# ==============================================================================

separator "PHASE 7 : Fermeture du tunnel"

close_tunnel
success "Port $SSH_PORT_MONITORING libéré — prêt pour les tests."

# ==============================================================================
# RÉSULTAT FINAL
# ==============================================================================

separator "SETUP MONITORING TERMINÉ"

echo "  Stack monitoring déployée sur $VM_MONITORING_NAME ($ENV)"
echo ""
echo "  ================================================================"
echo "  ACCÈS AUX INTERFACES (depuis l'ordinateur)"
echo "  ================================================================"
echo ""
echo "  Terminal 1 — tunnel Bastion vers VM monitoring (laisser ouvert) :"
echo "  az network bastion tunnel \\"
echo "    --name $BASTION_NAME \\"
echo "    --resource-group $RESOURCE_GROUP \\"
echo "    --target-resource-id $VM_MONITORING_ID \\"
echo "    --resource-port 22 \\"
echo "    --port 2222"
echo ""
echo "  Terminal 2 — port-forwarding SSH vers les services (laisser ouvert) :"
echo "  ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1 \\"
echo "    -L 3000:localhost:3000 \\"
echo "    -L 9090:localhost:9090 \\"
echo "    -L 9091:localhost:9091 \\"
echo "    -N"
echo ""
echo "  Terminal 3 — accès depuis l'ordinateur :"
echo "  Grafana     : http://localhost:3000  (admin / mot de passe saisi)"
echo "  Prometheus  : http://localhost:9090"
echo "  Pushgateway : http://localhost:9091"
echo ""
echo "  ================================================================"
echo "  CONNEXION SSH DIRECTE À LA VM (diagnostic et tests)"
echo "  ================================================================"
echo ""
echo "  Prérequis : tunnel Bastion ouvert (Terminal 1 ci-dessus)"
echo ""
echo "  ssh -i ~/.ssh/id_rsa_azure -p 2222 azureuser@127.0.0.1"
echo ""
echo "  Une fois connecté — commandes utiles :"
echo ""
echo "  # Statut des conteneurs Docker Compose"
echo "  docker compose -f /opt/monitoring/docker-compose.yml ps"
echo ""
echo "  # Logs en temps réel de tous les conteneurs"
echo "  docker compose -f /opt/monitoring/docker-compose.yml logs -f"
echo ""
echo "  # Logs d'un conteneur spécifique"
echo "  docker compose -f /opt/monitoring/docker-compose.yml logs --tail=50 grafana"
echo "  docker compose -f /opt/monitoring/docker-compose.yml logs --tail=50 prometheus"
echo "  docker compose -f /opt/monitoring/docker-compose.yml logs --tail=50 pushgateway"
echo ""
echo "  # Vérifier que les ports sont bien ouverts sur la VM"
echo "  curl -s http://localhost:3000/api/health | python3 -m json.tool"
echo "  curl -s http://localhost:9090/-/healthy"
echo "  curl -s http://localhost:9091/-/healthy"
echo ""
echo "  # Vérifier les métriques dans Pushgateway"
echo "  curl -s http://localhost:9091/metrics | grep -v '^#' | head -20"
echo ""
echo "  # Redémarrer un conteneur spécifique"
echo "  docker compose -f /opt/monitoring/docker-compose.yml restart grafana"
echo ""
echo "  # Redémarrer toute la stack"
echo "  docker compose -f /opt/monitoring/docker-compose.yml restart"
echo ""
echo "  ================================================================"
echo "  PROCHAINES ÉTAPES"
echo "  ================================================================"
echo ""
echo "  L'environnement $ENV et sa stack monitoring sont prêts."
echo "  Exécuter dans l'ordre :"
echo ""
echo "  1. Valider l'infrastructure $ENV :"
echo "     ./scripts/validate.sh $ENV"
echo ""
echo "  2. Exécuter tous les tests $ENV :"
echo "     ./tests/test-all.sh $ENV"
echo ""
echo "  3. Déployer staging :"
echo "     git push  (déclenche TFC automatiquement)"
echo "     ./scripts/setup-monitoring.sh staging"
echo ""
echo "  4. Déployer prod :"
echo "     git push  (déclenche TFC automatiquement)"
echo "     ./scripts/setup-monitoring.sh prod"
echo ""
echo "  5. Générer du trafic et observer le pipeline Event Hub → Grafana :"
echo "     ./scripts/generate-traffic.sh $ENV 15"
