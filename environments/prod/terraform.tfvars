# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : prod
# Fichier : terraform.tfvars
# Description : Valeurs des variables non-sensibles pour l'environnement prod.
#               Service Bus SKU Premium — isolation réseau native, SLA 99.95%.
#               Event Hub Standard 4 TU — capacité accrue pour la prod.
#               VM Flask D4s_v6 — 4 vCPU, 16 Go RAM.
#               purge_protection_enabled = true — protection contre la
#               suppression accidentelle du Key Vault.
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
environment    = "prod"
location       = "francecentral"

# Réseau — prod utilise le bloc 10.2.0.0/16
# Chaque environnement a son propre bloc pour éviter les conflits d'adressage
vnet_cidr                = "10.2.0.0/16"
subnet_bastion_prefix    = "10.2.3.0/27"
subnet_app_prefix        = "10.2.1.0/24"
subnet_monitoring_prefix = "10.2.4.0/24"
subnet_pe_prefix         = "10.2.2.0/24"

# Compute — D4s_v6 en prod : 4 vCPU, 16 Go RAM pour absorber la charge
# vm_ssh_public_key => configurée comme variable sensitive dans TFC
vm_size_app        = "Standard_D4s_v6"
vm_size_monitoring = "Standard_D2s_v6"

# Service Bus — Premium en prod : isolation réseau native, SLA 99.95%
servicebus_sku = "Premium"

# Event Hub — 4 TU en prod pour absorber les pics de métriques applicatives
eventhub_capacity        = 4
eventhub_partition_count = 2

# Key Vault — purge protection activée en prod pour éviter la suppression accidentelle
purge_protection_enabled = true

tags = {
  project = "phase8c"
  owner   = "palou"
}
