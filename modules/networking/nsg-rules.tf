# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : networking
# Fichier : nsg-rules.tf
# Description : Network Security Groups pour AzureBastionSubnet, snet-app,
#               snet-monitoring et snet-pe avec associations aux subnets.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# NSG — AzureBastionSubnet
# Règles imposées par Azure Bastion Standard SKU.
# Les ports 22 ET 3389 sont obligatoires en outbound vers VirtualNetwork —
# Azure rejette l'association si l'un des deux est absent, même sur Linux.
# ==============================================================================

resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-bastion-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  # --- Inbound ---

  security_rule {
    name                       = "Allow-HTTPS-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-GatewayManager-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Inbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-BastionHostComm-Inbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # --- Outbound ---

  # SSH et RDP obligatoires — Azure valide les deux même sur infrastructure Linux
  security_rule {
    name                       = "Allow-SSH-RDP-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-AzureCloud-Outbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "Allow-BastionHostComm-Outbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-GetSessionInfo-Outbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  subnet_id                 = azurerm_subnet.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

# ==============================================================================
# NSG — snet-app (VM Flask + consumer Event Hub)
# Outbound HTTP/HTTPS vers Internet obligatoire pour cloud-init (apt).
# Outbound vers snet-pe pour Service Bus (5671/5672 AMQP + 443 HTTPS)
# et Event Hub (5671/5672 AMQP + 443 HTTPS).
# AMQP est le protocole natif du SDK azure-servicebus et azure-eventhub —
# plus efficace que HTTPS pour la consommation de messages en continu.
# ==============================================================================

resource "azurerm_network_security_group" "app" {
  name                = "nsg-app-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  # --- Inbound ---

  security_rule {
    name                       = "Allow-Bastion-SSH-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.subnet_bastion_prefix
    destination_address_prefix = var.subnet_app_prefix
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # --- Outbound ---

  # HTTP vers Internet — apt pendant cloud-init
  security_rule {
    name                       = "Allow-HTTP-Internet-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = "Internet"
  }

  # HTTPS vers Internet — apt, pip, dépôts Microsoft
  security_rule {
    name                       = "Allow-HTTPS-Internet-Outbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = "Internet"
  }

  # AMQP vers Internet — Service Bus et Event Hub SKU Standard (dev/staging)
  # Sans Private Endpoint, le trafic AMQP sort vers les IPs publiques Azure.
  # Port 5671 : AMQP over TLS (production)
  # Port 5672 : AMQP plain (fallback SDK)
  security_rule {
    name                       = "Allow-AMQP-Internet-Outbound"
    priority                   = 115
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["5671", "5672"]
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = "Internet"
  }
  

  # HTTPS vers snet-pe — Service Bus et Event Hub (REST) + Key Vault
  security_rule {
    name                       = "Allow-App-to-PE-HTTPS-Outbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = var.subnet_pe_prefix
  }

  # AMQP vers snet-pe — protocole natif SDK azure-servicebus et azure-eventhub
  # Port 5671 : AMQP over TLS (production)
  # Port 5672 : AMQP plain (fallback SDK)
  security_rule {
    name                       = "Allow-App-to-PE-AMQP-Outbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["5671", "5672"]
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = var.subnet_pe_prefix
  }

  # Azure Active Directory — SDK azure-identity pour tokens Managed Identity
  security_rule {
    name                       = "Allow-App-to-AzureAD-Outbound"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = "AzureActiveDirectory"
  }

  # Azure Monitor — logs et métriques vers Log Analytics
  security_rule {
    name                       = "Allow-App-to-AzureMonitor-Outbound"
    priority                   = 150
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = "AzureMonitor"
  }

  # Pushgateway sur snet-monitoring — consumer envoie les métriques Event Hub
  security_rule {
    name                       = "Allow-App-to-Pushgateway-Outbound"
    priority                   = 160
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9091"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = var.subnet_monitoring_prefix
  }

  security_rule {
    name                       = "Deny-All-Outbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ==============================================================================
# NSG — snet-monitoring (VM Prometheus / Grafana / Pushgateway)
# Inbound depuis snet-app pour Pushgateway :9091 (consumer → métriques)
# Inbound depuis Bastion pour SSH
# Outbound HTTP/HTTPS vers Internet pour cloud-init et images Docker
# ==============================================================================

resource "azurerm_network_security_group" "monitoring" {
  name                = "nsg-monitoring-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  # --- Inbound ---

  security_rule {
    name                       = "Allow-Bastion-SSH-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.subnet_bastion_prefix
    destination_address_prefix = var.subnet_monitoring_prefix
  }

  # Pushgateway depuis snet-app — consumer pousse les métriques Event Hub
  security_rule {
    name                       = "Allow-App-to-Pushgateway-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9091"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = var.subnet_monitoring_prefix
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # --- Outbound ---

  security_rule {
    name                       = "Allow-HTTP-Internet-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = var.subnet_monitoring_prefix
    destination_address_prefix = "Internet"
  }

  # HTTPS vers Internet — apt, pip, images Docker Hub
  security_rule {
    name                       = "Allow-HTTPS-Internet-Outbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_monitoring_prefix
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "Deny-All-Outbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "monitoring" {
  subnet_id                 = azurerm_subnet.monitoring.id
  network_security_group_id = azurerm_network_security_group.monitoring.id
}

# ==============================================================================
# NSG — snet-pe (Private Endpoints)
# Fonctionne grâce à private_endpoint_network_policies = "Enabled" sur snet-pe.
# Inbound depuis snet-app uniquement — HTTPS (443) et AMQP (5671/5672).
# ==============================================================================

resource "azurerm_network_security_group" "pe" {
  name                = "nsg-pe-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  # --- Inbound ---

  security_rule {
    name                       = "Allow-App-to-PE-HTTPS-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = var.subnet_pe_prefix
  }

  security_rule {
    name                       = "Allow-App-to-PE-AMQP-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["5671", "5672"]
    source_address_prefix      = var.subnet_app_prefix
    destination_address_prefix = var.subnet_pe_prefix
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}
