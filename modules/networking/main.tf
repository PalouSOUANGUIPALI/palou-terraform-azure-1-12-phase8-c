# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : networking
# Fichier : main.tf
# Description : Resource Group, VNet, 4 subnets, NSGs, zones DNS privées
#               et Log Analytics Workspace.
#               Quatre subnets :
#                 AzureBastionSubnet — Azure Bastion Standard SKU
#                 snet-app           — VM Flask + consumer Event Hub
#                 snet-monitoring    — VM Prometheus / Grafana / Pushgateway
#                 snet-pe            — Private Endpoints Service Bus, Event Hub, Key Vault
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# LOCALS
# ==============================================================================

locals {
  prefix = "${var.project_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "networking"
    environment = var.environment
    phase       = "8c"
    managed_by  = "terraform"
  })
}

# ==============================================================================
# RESOURCE GROUP
# ==============================================================================

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.prefix}"
  location = var.location
  tags     = local.common_tags
}

# ==============================================================================
# VIRTUAL NETWORK
# ==============================================================================

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.common_tags
}

# ==============================================================================
# SUBNETS
# ==============================================================================

# Azure Bastion — nom imposé par Azure, ne pas modifier
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_bastion_prefix]
}

# snet-app — VM Flask + service eventhub-consumer
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_app_prefix]
}

# snet-monitoring — VM Prometheus / Grafana / Pushgateway (Docker Compose)
resource "azurerm_subnet" "monitoring" {
  name                 = "snet-monitoring"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_monitoring_prefix]
}

# snet-pe — Private Endpoints Service Bus, Event Hub, Key Vault
# private_endpoint_network_policies = "Enabled" permet d'appliquer
# les règles NSG aux Private Endpoints dans ce subnet
resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_pe_prefix]

  private_endpoint_network_policies = "Enabled"
}

# ==============================================================================
# NSG — voir nsg-rules.tf
# ==============================================================================

# ==============================================================================
# ZONES DNS PRIVÉES
# Service Bus et Event Hub partagent la même zone DNS privée —
# privatelink.servicebus.windows.net est utilisée pour les deux services.
# Key Vault a sa propre zone.
# ==============================================================================

resource "azurerm_private_dns_zone" "servicebus" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

# ==============================================================================
# LIENS DNS — VNet
# Chaque zone DNS privée doit être liée au VNet pour que la résolution
# DNS fonctionne depuis les VMs. Sans ce lien, les FQDNs des services
# PaaS résoudraient vers des IPs publiques malgré les Private Endpoints.
# ==============================================================================

resource "azurerm_private_dns_zone_virtual_network_link" "servicebus" {
  name                  = "link-servicebus-${local.prefix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.servicebus.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "link-keyvault-${local.prefix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.common_tags
}

# ==============================================================================
# LOG ANALYTICS WORKSPACE
# Déployé dans le module networking car il est partagé par tous les modules.
# Chaque module de service reçoit le LAW ID en variable et crée ses propres
# diagnostic settings.
# ==============================================================================

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}
