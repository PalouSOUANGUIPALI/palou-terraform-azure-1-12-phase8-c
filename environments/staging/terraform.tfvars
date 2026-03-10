# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : staging
# Fichier : terraform.tfvars
# Description : Valeurs des variables non-sensibles pour l'environnement staging.
#               Même configuration que dev — VNet 10.1.0.0/16.
#
#               Variables sensibles absentes de ce fichier — configurées dans
#               Terraform Cloud via scripts/setup-azure.sh :
#                 subscription_id              — ID de l'abonnement Azure
#                 tenant_id                    — ID du tenant Azure AD
#                 client_id                    — App ID du Service Principal
#                 client_secret                — Secret du Service Principal
#                 vm_ssh_public_key            — Contenu de ~/.ssh/azure-phase8c.pub
#                 servicebus_connection_string — Connection string Service Bus
#                 eventhub_connection_string   — Connection string Event Hub
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

project_prefix = "phase8c"
environment    = "staging"
location       = "francecentral"

# Réseau — staging utilise le bloc 10.1.0.0/16
# Chaque environnement a son propre bloc pour éviter les conflits d'adressage
vnet_cidr                = "10.1.0.0/16"
subnet_bastion_prefix    = "10.1.3.0/27"
subnet_app_prefix        = "10.1.1.0/24"
subnet_monitoring_prefix = "10.1.4.0/24"
subnet_pe_prefix         = "10.1.2.0/24"

# Compute — Standard_D2s_v6 : 2 vCPU, 8 Go RAM, suffisant pour le staging
# vm_ssh_public_key => configurée comme variable sensitive dans TFC
vm_size_app        = "Standard_D2s_v6"
vm_size_monitoring = "Standard_D2s_v6"

# Service Bus — Standard requis pour les topics et subscriptions
servicebus_sku = "Standard"

# Event Hub — 2 TU suffisants pour le staging
eventhub_capacity        = 2
eventhub_partition_count = 2

# Key Vault — purge protection désactivée en staging pour faciliter les redeploiements
purge_protection_enabled = false

tags = {
  project = "phase8c"
  owner   = "palou"
}
