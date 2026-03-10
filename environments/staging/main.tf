# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : staging
# Fichier : main.tf
# Description : Assemblage des modules pour l'environnement staging.
#               Structure identique à dev — seules les valeurs diffèrent
#               (VNet 10.1.0.0/16, SKU Standard, 2 TU).
# Auteur : Palou
# Date : Mars 2026
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
  key_vault_url        = "https://${var.project_prefix}-${var.environment}-kv.vault.azure.net/"

  tags = var.tags

  depends_on = [module.networking]
}

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
