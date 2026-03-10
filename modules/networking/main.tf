# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : networking
# Fichier : main.tf
# Description : Resource Group, VNet, 4 subnets, NSGs, zones DNS privées.
#               Quatre subnets :
#                 AzureBastionSubnet — Azure Bastion Standard SKU
#                 snet-app           — VM Flask + consumer Event Hub
#                 snet-monitoring    — VM Prometheus / Grafana / Pushgateway
#                 snet-pe            — Private Endpoints Service Bus, Event Hub, Key Vault
#               Le Log Analytics Workspace est déployé dans le module monitoring
#               et non ici — il reçoit les diagnostic settings de tous les modules.
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
# AZURE BASTION
# SKU Standard requis pour les tunnels TCP natifs (az network bastion tunnel).
# Déployé dans AzureBastionSubnet — nom imposé par Azure.
# Fournit l'accès SSH sécurisé aux deux VMs sans IP publique (zero-trust).
# ==============================================================================

resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_bastion_host" "main" {
  name                = "bastion-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tunneling_enabled   = true
  tags                = local.common_tags

  ip_configuration {
    name                 = "ipconfig-bastion-${local.prefix}"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
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
