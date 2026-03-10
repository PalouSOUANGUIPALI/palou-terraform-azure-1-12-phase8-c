# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : staging
# Fichier : backend.tf
# Description : Configuration du backend Terraform Cloud.
#               Workflow VCS-driven — les apply sont declenchés par git push,
#               jamais par terraform apply local.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

terraform {
  cloud {
    organization = "palou-terraform-azure-1-12-phase8-c"

    workspaces {
      name = "phase8c-staging"
    }
  }
}
