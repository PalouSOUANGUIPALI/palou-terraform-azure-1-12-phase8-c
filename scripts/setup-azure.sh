#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : setup-azure.sh
# Description : Configuration initiale complète pour Phase 8C.
#               1. Vérifie les prérequis (CLI, connexions)
#               2. Crée les 3 workspaces dans Terraform Cloud
#               3. Configure les variables sensitives
#                  (credentials Azure, clé SSH)
#               4. Valide les fichiers Terraform
#
#               Les connection strings Service Bus et Event Hub sont
#               dérivés des outputs des modules Terraform — ils ne
#               sont pas des variables TFC.
#
#               Pas de remote state partagé entre workspaces :
#               chaque environnement est totalement indépendant.
#
# Prérequis :
#   - Terraform CLI installé (>= 1.6)
#   - Azure CLI installé et connecté (az login)
#   - Connexion à TFC (terraform login)
#   - Organisation TFC existante
#
# Usage :
#   ./scripts/setup-azure.sh
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

WORKSPACES=(
  "phase8c-dev:environments/dev"
  "phase8c-staging:environments/staging"
  "phase8c-prod:environments/prod"
)

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

create_or_update_variable() {
  local ws_id="$1"
  local key="$2"
  local value="$3"
  local sensitive="$4"

  local existing_id
  existing_id=$(curl -s \
    --header "Authorization: Bearer $TFC_TOKEN" \
    "$TFC_API/workspaces/$ws_id/vars" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for v in data.get('data', []):
    if v['attributes']['key'] == '$key' and v['attributes']['category'] == 'terraform':
        print(v['id'])
        break
" 2>/dev/null || echo "")

  local RESPONSE
  if [ -n "$existing_id" ]; then
    RESPONSE=$(printf '%s' "$value" | python3 -c "
import json, sys
value = sys.stdin.read()
payload = json.dumps({
    'data': {
        'type': 'vars',
        'id': '$existing_id',
        'attributes': {
            'value': value,
            'sensitive': True if '$sensitive' == 'true' else False
        }
    }
})
print(payload)
" | curl -s \
      --header "Authorization: Bearer $TFC_TOKEN" \
      --header "Content-Type: application/vnd.api+json" \
      --request PATCH \
      --data @- \
      "$TFC_API/workspaces/$ws_id/vars/$existing_id")
  else
    RESPONSE=$(printf '%s' "$value" | python3 -c "
import json, sys
value = sys.stdin.read()
payload = json.dumps({
    'data': {
        'type': 'vars',
        'attributes': {
            'key': '$key',
            'value': value,
            'category': 'terraform',
            'sensitive': True if '$sensitive' == 'true' else False
        }
    }
})
print(payload)
" | curl -s \
      --header "Authorization: Bearer $TFC_TOKEN" \
      --header "Content-Type: application/vnd.api+json" \
      --request POST \
      --data @- \
      "$TFC_API/workspaces/$ws_id/vars")
  fi

  if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'data' in d" 2>/dev/null; then
    if [ -n "$existing_id" ]; then
      info "$key : mis à jour"
    else
      info "$key : créé"
    fi
  else
    error "$key : échec"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "    $RESPONSE"
  fi
}

read_visible() {
  local prompt="$1"
  local value=""
  read -p "  $prompt" value
  echo "$value"
}

# ==============================================================================
# PHASE 1 : VÉRIFICATION DES PRÉREQUIS
# ==============================================================================

separator "PHASE 1 : Vérification des prérequis"

PREREQS_OK=true

# Terraform CLI
if command -v terraform &> /dev/null; then
  TF_VERSION=$(terraform version -json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null \
    || terraform version | head -1)
  success "Terraform CLI : $TF_VERSION"
else
  error "Terraform CLI non installé."
  echo "         Installation : brew install terraform"
  PREREQS_OK=false
fi

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

# Git
if command -v git &> /dev/null; then
  success "Git : $(git version | cut -d' ' -f3)"
else
  error "Git non installé."
  PREREQS_OK=false
fi

# curl
if command -v curl &> /dev/null; then
  success "curl : OK"
else
  error "curl non installé."
  PREREQS_OK=false
fi

# python3
if command -v python3 &> /dev/null; then
  success "python3 : $(python3 --version | cut -d' ' -f2)"
else
  error "python3 non installé."
  PREREQS_OK=false
fi

# Token TFC
if [ -f "$TFC_TOKEN_FILE" ]; then
  TFC_TOKEN=$(get_tfc_token || echo "")
  if [ -n "$TFC_TOKEN" ]; then
    success "Token TFC : OK"
  else
    error "Token TFC illisible."
    echo "         Exécutez : terraform login"
    PREREQS_OK=false
  fi
else
  error "Pas de token TFC trouvé."
  echo "         Exécutez : terraform login"
  PREREQS_OK=false
fi

# Organisation TFC
if [ "$PREREQS_OK" = true ] && [ -n "${TFC_TOKEN:-}" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "Authorization: Bearer $TFC_TOKEN" \
    "$TFC_API/organizations/$TFC_ORG")
  if [ "$HTTP_CODE" = "200" ]; then
    success "Organisation TFC : $TFC_ORG"
  else
    error "Organisation TFC '$TFC_ORG' introuvable (HTTP $HTTP_CODE)."
    echo "         Créez-la sur https://app.terraform.io"
    PREREQS_OK=false
  fi
fi

if [ "$PREREQS_OK" = false ]; then
  echo ""
  error "Des prérequis manquent. Corrigez les erreurs ci-dessus."
  exit 1
fi

echo ""
success "Tous les prérequis sont satisfaits."

# ==============================================================================
# PHASE 2 : CRÉATION DES WORKSPACES TFC
# ==============================================================================

separator "PHASE 2 : Création des workspaces TFC"

CREATED=0
SKIPPED=0

for ENTRY in "${WORKSPACES[@]}"; do
  WS_NAME="${ENTRY%%:*}"
  WORKING_DIR="${ENTRY##*:}"

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "Authorization: Bearer $TFC_TOKEN" \
    "$TFC_API/organizations/$TFC_ORG/workspaces/$WS_NAME")

  if [ "$HTTP_CODE" = "200" ]; then
    info "$WS_NAME : existe déjà"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  RESPONSE=$(curl -s \
    --header "Authorization: Bearer $TFC_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --request POST \
    --data '{
      "data": {
        "type": "workspaces",
        "attributes": {
          "name": "'"$WS_NAME"'",
          "working-directory": "'"$WORKING_DIR"'",
          "auto-apply": false,
          "terraform-version": "~> 1.6",
          "description": "Phase 8C - Messaging et Integration - '"$WS_NAME"'"
        }
      }
    }' \
    "$TFC_API/organizations/$TFC_ORG/workspaces")

  WS_ID=$(echo "$RESPONSE" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo "")

  if [ -n "$WS_ID" ]; then
    success "$WS_NAME : créé (ID: $WS_ID)"
    CREATED=$((CREATED + 1))
  else
    error "Échec de la création de $WS_NAME"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    exit 1
  fi
done

echo ""
info "Créés : $CREATED | Déjà existants : $SKIPPED"

# ==============================================================================
# PHASE 3 : CONFIGURATION DES VARIABLES
# ==============================================================================

separator "PHASE 3 : Configuration des variables"

echo "  Les credentials Azure et la clé SSH seront stockés comme"
echo "  variables Terraform sensitives dans TFC."
echo "  Jamais dans le code source."
echo ""
echo "  Où trouver les credentials dans le portail Azure :"
echo "    subscription_id : Abonnements > votre abonnement > ID d'abonnement"
echo "    tenant_id       : Microsoft Entra ID > Vue d'ensemble > ID du locataire"
echo "    client_id       : Entra ID > Inscriptions d'applications > votre SP > ID d'application"
echo "    client_secret   : Entra ID > Inscriptions d'applications > votre SP > Certificats et secrets"
echo ""
echo "  Note : les connection strings Service Bus et Event Hub sont dérivés"
echo "  automatiquement des outputs des modules Terraform — ils ne sont pas"
echo "  des variables TFC."
echo ""

# Credentials Azure
SUB_ID=$(read_visible "subscription_id : ")
if [ -z "$SUB_ID" ]; then error "subscription_id est obligatoire."; exit 1; fi

TENANT_ID=$(read_visible "tenant_id : ")
if [ -z "$TENANT_ID" ]; then error "tenant_id est obligatoire."; exit 1; fi

CLIENT_ID=$(read_visible "client_id : ")
if [ -z "$CLIENT_ID" ]; then error "client_id est obligatoire."; exit 1; fi

CLIENT_SECRET=$(read_visible "client_secret : ")
if [ -z "$CLIENT_SECRET" ]; then error "client_secret est obligatoire."; exit 1; fi

# Clé SSH
echo ""
SSH_KEY_FILE="$HOME/.ssh/id_rsa_azure"
if [ ! -f "$SSH_KEY_FILE" ]; then
  error "Clé SSH introuvable : $SSH_KEY_FILE"
  echo "         Générez-la avec :"
  echo "         ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure"
  exit 1
fi
SSH_KEY=$(cat "$SSH_KEY_FILE")
info "Clé SSH lue depuis $SSH_KEY_FILE"

echo ""
echo "  --- Application des variables ---"

for ENTRY in "${WORKSPACES[@]}"; do
  WS_NAME="${ENTRY%%:*}"
  echo ""
  info "Workspace : $WS_NAME"
  WS_ID=$(get_workspace_id "$WS_NAME")
  if [ -z "$WS_ID" ]; then error "Workspace $WS_NAME introuvable."; exit 1; fi

  create_or_update_variable "$WS_ID" "subscription_id"   "$SUB_ID"        "true"
  create_or_update_variable "$WS_ID" "tenant_id"         "$TENANT_ID"     "true"
  create_or_update_variable "$WS_ID" "client_id"         "$CLIENT_ID"     "true"
  create_or_update_variable "$WS_ID" "client_secret"     "$CLIENT_SECRET" "true"
  create_or_update_variable "$WS_ID" "vm_ssh_public_key" "$SSH_KEY"       "true"
done

# ==============================================================================
# PHASE 4 : VALIDATION DES FICHIERS
# ==============================================================================

separator "PHASE 4 : Validation des fichiers Terraform"

ERRORS=0

# Formatage automatique
echo "--- Formatage automatique ---"
terraform fmt -recursive modules/ > /dev/null 2>&1
success "modules/ : formaté"
terraform fmt -recursive environments/ > /dev/null 2>&1
success "environments/ : formaté"
echo ""

# Modules
echo "--- Modules ---"
for MODULE in modules/*/; do
  MODULE_NAME=$(basename "$MODULE")
  for FILE in "main.tf" "variables.tf" "outputs.tf"; do
    if [ ! -f "$MODULE/$FILE" ]; then
      error "$FILE manquant dans modules/$MODULE_NAME"
      ERRORS=$((ERRORS + 1))
    fi
  done

  FMT_OUTPUT=$(terraform fmt -check -diff -recursive "$MODULE" 2>&1 || true)
  if [ -n "$FMT_OUTPUT" ]; then
    error "Format incorrect dans modules/$MODULE_NAME"
    ERRORS=$((ERRORS + 1))
  else
    success "modules/$MODULE_NAME : OK"
  fi
done

echo ""
echo "--- Environnements ---"
for ENV in "dev" "staging" "prod"; do
  ENV_PATH="environments/$ENV"
  if [ ! -d "$ENV_PATH" ]; then
    error "Répertoire $ENV_PATH introuvable"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  for FILE in "main.tf" "variables.tf" "outputs.tf" "providers.tf" "backend.tf" "terraform.tfvars"; do
    if [ ! -f "$ENV_PATH/$FILE" ]; then
      error "$FILE manquant dans $ENV_PATH"
      ERRORS=$((ERRORS + 1))
    fi
  done

  FMT_OUTPUT=$(terraform fmt -check -diff -recursive "$ENV_PATH" 2>&1 || true)
  if [ -n "$FMT_OUTPUT" ]; then
    error "Format incorrect dans $ENV_PATH"
    ERRORS=$((ERRORS + 1))
  else
    success "environments/$ENV : OK"
  fi
done

echo ""
echo "--- Application Flask ---"
for FILE in "app/main.py" "app/consumer.py" "app/requirements.txt" "app/startup.sh" "app/consumer-startup.sh"; do
  if [ -f "$FILE" ]; then
    success "$FILE existe"
  else
    error "$FILE introuvable"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "--- Monitoring ---"
for FILE in "monitoring/docker-compose.yml" "monitoring/prometheus.yml" "monitoring/grafana/provisioning/dashboards/dashboard-eventhub.json"; do
  if [ -f "$FILE" ]; then
    success "$FILE existe"
  else
    error "$FILE introuvable"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ $ERRORS -gt 0 ]; then
  echo ""
  error "$ERRORS erreur(s) détectée(s). Corrigez avant de continuer."
  exit 1
fi

# ==============================================================================
# RÉSULTAT FINAL
# ==============================================================================

separator "SETUP TERMINÉ"

echo "  Tout est prêt pour le premier déploiement."
echo ""
echo "  Prochaines étapes :"
echo ""
echo "  1. Premier commit et push :"
echo "     git add ."
echo "     git commit -m 'Phase 8C initial'"
echo "     git push"
echo ""
echo "  2. Déployer les environnements :"
echo "     ./scripts/deploy-dev.sh"
echo "     ./scripts/deploy-staging.sh"
echo "     ./scripts/deploy-prod.sh"
echo ""
echo "  Ou tout déployer d'un coup :"
echo "     ./scripts/deploy-all.sh"
