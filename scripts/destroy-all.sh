#!/bin/bash
# ==============================================================================
# Phase 8C - Messaging et Integration
# Script : destroy-all.sh
# Description : Détruit tous les environnements dans l'ordre inverse
#               du déploiement :
#               1. prod
#               2. staging
#               3. dev
#
#               Chaque destruction doit être approuvée dans TFC.
#
#               ATTENTION : Action IRREVERSIBLE.
#               Toutes les ressources Azure seront supprimées
#               définitivement, y compris les namespaces Service Bus
#               et Event Hub et leurs données.
#
# Prérequis :
#   - Connexion à TFC (terraform login)
#
# Usage :
#   ./scripts/destroy-all.sh
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
# AVERTISSEMENT
# ==============================================================================

echo ""
echo "  ========================================="
echo "  !!   DESTRUCTION COMPLETE              !!"
echo "  ========================================="
echo ""
echo "  Ceci va détruire TOUS les environnements :"
echo "    1. prod"
echo "    2. staging"
echo "    3. dev"
echo ""
echo "  Les ressources suivantes seront supprimées"
echo "  définitivement dans chaque environnement :"
echo "    - VM Flask et VM Monitoring"
echo "    - Azure Bastion"
echo "    - Service Bus Namespace (queues, topics, DLQ)"
echo "    - Event Hub Namespace (app-metrics, consumer groups)"
echo "    - Key Vault et ses secrets"
echo "    - Log Analytics Workspace et ses logs"
echo "    - VNet, subnets, NSGs"
echo "    - Private Endpoints et zones DNS privées"
echo "    - Resource Groups rg-phase8c-{dev,staging,prod}"
echo ""
read -p "  Tapez 'DESTROY ALL' pour confirmer : " CONFIRM

if [ "$CONFIRM" != "DESTROY ALL" ]; then
  echo "  Annulé."
  exit 0
fi

echo ""

# ==============================================================================
# DESTRUCTION DANS L'ORDRE INVERSE
# ==============================================================================

for ENV in "prod" "staging" "dev"; do
  echo ""
  echo "=== Destruction de $ENV ==="
  echo ""

  if [ "$ENV" = "prod" ]; then
    echo "  ATTENTION : Vous allez détruire la PRODUCTION."
    echo "  Le Service Bus Premium et l'Event Hub 4 TU seront"
    echo "  supprimés définitivement."
    echo ""
  fi

  read -p "  Détruire $ENV ? (o/n) : " DO_DESTROY
  if [ "$DO_DESTROY" = "o" ] || [ "$DO_DESTROY" = "O" ]; then
    ./scripts/destroy-env.sh "$ENV"
    echo ""
    echo "  Approuvez le destroy dans TFC :"
    echo "  https://app.terraform.io/app/palou-terraform-azure-1-12-phase8-c/workspaces/phase8c-$ENV"
    echo ""
    read -p "  $ENV détruit ? (o/n) : " DONE
    if [ "$DONE" != "o" ] && [ "$DONE" != "O" ]; then
      echo "  [ATTEN.] $ENV marqué comme non détruit."
      echo "  Vérifiez dans TFC avant de continuer."
      read -p "  Continuer quand même ? (o/n) : " FORCE
      if [ "$FORCE" != "o" ] && [ "$FORCE" != "O" ]; then
        echo "  Destruction interrompue."
        exit 0
      fi
    fi
  else
    echo "  $ENV ignoré."
  fi
done

# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo ""
echo "=== Destruction complète terminée ==="
echo ""
echo "  Vérifiez dans le portail Azure que tous"
echo "  les Resource Groups ont bien été supprimés :"
echo "    rg-phase8c-dev"
echo "    rg-phase8c-staging"
echo "    rg-phase8c-prod"
echo ""
echo "  Si des ressources persistent, supprimez-les"
echo "  manuellement depuis le portail Azure :"
echo "    az group delete --name rg-phase8c-dev --yes"
echo "    az group delete --name rg-phase8c-staging --yes"
echo "    az group delete --name rg-phase8c-prod --yes"
