# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : dev
# Fichier : main.tf
# Description : Assemblage des modules pour l'environnement dev.
#               Ordre des dépendances :
#                 1. monitoring  — Log Analytics Workspace + Action Group
#                 2. networking  — VNet, subnets, NSGs, zones DNS
#                 3. service-bus — Namespace, queue, topic, PE
#                 4. event-hub   — Namespace, Event Hub, consumer group, PE
#                 5. compute     — VMs Flask et Monitoring (après KV pour l'URI)
#                 6. key-vault   — KV, RBAC, secrets (après compute pour MI ID)
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# MODULE MONITORING
# Déployé en premier — le Log Analytics Workspace ID est passé
# aux modules service-bus, event-hub et key-vault pour leurs
# diagnostic settings.
# ==============================================================================

module "monitoring" {
  source = "../../modules/monitoring"

  project_prefix      = var.project_prefix
  environment         = var.environment
  location            = var.location
  resource_group_name = module.networking.resource_group_name

  tags = var.tags

  depends_on = [module.networking]
}

# ==============================================================================
# MODULE NETWORKING
# VNet, 4 subnets, NSGs, zones DNS privées.
# Fournit les IDs de subnet et de zone DNS à tous les autres modules.
# ==============================================================================

module "networking" {
  source = "../../modules/networking"

  project_prefix           = var.project_prefix
  environment              = var.environment
  location                 = var.location
  vnet_cidr                = var.vnet_cidr
  subnet_bastion_prefix    = var.subnet_bastion_prefix
  subnet_app_prefix        = var.subnet_app_prefix
  subnet_monitoring_prefix = var.subnet_monitoring_prefix
  subnet_pe_prefix         = var.subnet_pe_prefix

  tags = var.tags
}

# ==============================================================================
# MODULE SERVICE BUS
# Namespace, queue orders, topic events + subscriptions, Private Endpoint.
# ==============================================================================

module "service_bus" {
  source = "../../modules/service-bus"

  project_prefix                 = var.project_prefix
  environment                    = var.environment
  location                       = var.location
  resource_group_name            = module.networking.resource_group_name
  servicebus_sku                 = var.servicebus_sku
  subnet_pe_id                   = module.networking.subnet_pe_id
  private_dns_zone_servicebus_id = module.networking.private_dns_zone_servicebus_id
  log_analytics_workspace_id     = module.monitoring.log_analytics_workspace_id

  tags = var.tags

  depends_on = [module.networking, module.monitoring]
}

# ==============================================================================
# MODULE EVENT HUB
# Namespace, Event Hub app-metrics, consumer group grafana, Private Endpoint.
# Partage la zone DNS privatelink.servicebus.windows.net avec Service Bus.
# ==============================================================================

module "event_hub" {
  source = "../../modules/event-hub"

  project_prefix                 = var.project_prefix
  environment                    = var.environment
  location                       = var.location
  resource_group_name            = module.networking.resource_group_name
  eventhub_capacity              = var.eventhub_capacity
  eventhub_partition_count       = var.eventhub_partition_count
  subnet_pe_id                   = module.networking.subnet_pe_id
  private_dns_zone_servicebus_id = module.networking.private_dns_zone_servicebus_id
  log_analytics_workspace_id     = module.monitoring.log_analytics_workspace_id

  tags = var.tags

  depends_on = [module.networking, module.monitoring]
}

# ==============================================================================
# MODULE COMPUTE
# VM Flask (snet-app) + VM Monitoring (snet-monitoring).
# La VM Flask reçoit l'URI Key Vault via cloud-init — le module key-vault
# est donc déclaré avant compute pour fournir cet output.
# Mais key-vault a besoin du principal ID de la VM pour le RBAC —
# on résout cette dépendance circulaire en passant l'URI Key Vault
# via une variable calculée localement.
# ==============================================================================

module "compute" {
  source = "../../modules/compute"

  project_prefix       = var.project_prefix
  environment          = var.environment
  location             = var.location
  resource_group_name  = module.networking.resource_group_name
  subnet_app_id        = module.networking.subnet_app_id
  subnet_monitoring_id = module.networking.subnet_monitoring_id
  vm_size_app          = var.vm_size_app
  vm_size_monitoring   = var.vm_size_monitoring
  vm_ssh_public_key    = var.vm_ssh_public_key

  # L'URI Key Vault est construite localement — elle suit une convention
  # Azure prévisible sans dépendre du module key-vault, ce qui évite
  # la dépendance circulaire compute <-> key-vault.
  key_vault_url = "https://${var.project_prefix}-${var.environment}-kv.vault.azure.net/"

  tags = var.tags

  depends_on = [module.networking]
}

# ==============================================================================
# MODULE KEY VAULT
# Key Vault, RBAC, secrets Service Bus et Event Hub, Private Endpoint.
# Déployé après compute pour récupérer le principal ID de la VM Flask.
# ==============================================================================

module "key_vault" {
  source = "../../modules/key-vault"

  project_prefix               = var.project_prefix
  environment                  = var.environment
  location                     = var.location
  resource_group_name          = module.networking.resource_group_name
  purge_protection_enabled     = var.purge_protection_enabled
  subnet_pe_id                 = module.networking.subnet_pe_id
  private_dns_zone_keyvault_id = module.networking.private_dns_zone_keyvault_id
  vm_app_identity_principal_id = module.compute.vm_app_identity_principal_id
  servicebus_connection_string = module.service_bus.connection_string
  eventhub_connection_string   = module.event_hub.connection_string
  log_analytics_workspace_id   = module.monitoring.log_analytics_workspace_id

  tags = var.tags

  depends_on = [module.networking, module.compute, module.monitoring]
}
