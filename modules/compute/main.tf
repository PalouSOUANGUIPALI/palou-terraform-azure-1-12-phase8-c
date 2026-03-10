# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : compute
# Fichier : main.tf
# Description : Deux VMs Ubuntu 22.04 :
#               vm-app        — Flask + consumer Event Hub (snet-app)
#               vm-monitoring — Prometheus + Grafana + Pushgateway (snet-monitoring)
#               Les deux VMs sont initialisées via cloud-init.
#               Aucune IP publique — accès exclusivement via Azure Bastion.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# LOCALS
# ==============================================================================

locals {
  prefix = "${var.project_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "compute"
    environment = var.environment
    phase       = "8c"
    managed_by  = "terraform"
  })
}

# ==============================================================================
# IP PUBLIQUES — AUCUNE
# Les VMs n'ont pas d'IP publique. L'accès SSH passe exclusivement par
# Azure Bastion. C'est le modèle zero-trust appliqué à toutes les phases.
# ==============================================================================

# ==============================================================================
# NIC — VM APP
# ==============================================================================

resource "azurerm_network_interface" "app" {
  name                = "nic-app-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig-app"
    subnet_id                     = var.subnet_app_id
    private_ip_address_allocation = "Dynamic"
  }
}

# ==============================================================================
# NIC — VM MONITORING
# ==============================================================================

resource "azurerm_network_interface" "monitoring" {
  name                = "nic-monitoring-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig-monitoring"
    subnet_id                     = var.subnet_monitoring_id
    private_ip_address_allocation = "Dynamic"
  }
}

# ==============================================================================
# VM APP — Flask + consumer Event Hub
# cloud-init-app.tftpl installe Python, les dépendances Flask et le consumer,
# configure les deux services systemd : flask-app et eventhub-consumer.
# ==============================================================================

resource "azurerm_linux_virtual_machine" "app" {
  name                  = "vm-${local.prefix}-app"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size_app
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.app.id]
  tags                  = local.common_tags

  # Managed Identity system-assigned — utilisée pour lire Key Vault
  # sans stocker de credentials dans la VM ou dans TFC
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.vm_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init rendu par templatefile() au moment du plan Terraform.
  # Les variables KEY_VAULT_URL et APP_ENV sont injectées dans le service
  # systemd flask-app — elles ne sont jamais écrites en clair dans un fichier.
  custom_data = base64encode(templatefile("${path.module}/cloud-init-app.tftpl", {
    key_vault_url = var.key_vault_url
    environment   = var.environment
  }))
}

# ==============================================================================
# VM MONITORING — Prometheus + Grafana + Pushgateway
# cloud-init-monitoring.tftpl installe Docker, Docker Compose, copie les
# fichiers de configuration et démarre la stack via docker-compose.
# ==============================================================================

resource "azurerm_linux_virtual_machine" "monitoring" {
  name                  = "vm-${local.prefix}-monitoring"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size_monitoring
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.monitoring.id]
  tags                  = local.common_tags

  # La VM monitoring n'a pas de Managed Identity — elle n'accède
  # à aucun service Azure PaaS directement. Prometheus scrape Pushgateway
  # en interne, Grafana lit Prometheus — tout reste dans snet-monitoring.
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.vm_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init-monitoring.tftpl", {
    environment              = var.environment
    monitoring_vm_private_ip = azurerm_network_interface.monitoring.private_ip_address
  }))
}
