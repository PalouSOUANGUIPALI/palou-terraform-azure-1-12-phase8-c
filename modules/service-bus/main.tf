# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
# Fichier : main.tf
# Description : Service Bus Namespace avec SKU Standard (dev/staging)
#               ou Premium (prod). Le namespace héberge la queue orders
#               et le topic events — définis dans queues.tf et topics.tf.
#               Private Endpoint dans private-endpoint.tf.
#               Diagnostic settings dans diagnostic.tf.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# ==============================================================================
# LOCALS
# ==============================================================================

locals {
  prefix = "${var.project_prefix}-${var.environment}"

  common_tags = merge(var.tags, {
    module      = "service-bus"
    environment = var.environment
    phase       = "8c"
    managed_by  = "terraform"
  })
}

# ==============================================================================
# SERVICE BUS NAMESPACE
# SKU Standard — minimum requis pour les topics et subscriptions.
# SKU Basic ne supporte que les queues, pas les topics.
# SKU Premium offre l'isolation réseau complète (VNET integration native)
# mais est réservé à prod pour des raisons de coût.
#
# publicNetworkAccess = false — accès uniquement via Private Endpoint.
# TFC n'a pas besoin d'accéder au namespace directement (contrairement
# à Key Vault) — les connection strings sont lus via az CLI ou outputs.
# ==============================================================================

resource "azurerm_servicebus_namespace" "main" {
  name                = "sb-${local.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.servicebus_sku

  # Accès public désactivé uniquement en prod (SKU Premium + Private Endpoint).
  # En dev/staging (SKU Standard), pas de Private Endpoint — accès public
  # requis pour que la VM puisse atteindre le namespace via Internet Azure.
  public_network_access_enabled = var.servicebus_sku == "Premium" ? false : true

  minimum_tls_version = "1.2"

  # SAS keys désactivées uniquement en prod (SKU Premium).
  # En dev/staging, la connection string SAS stockée dans Key Vault
  # est utilisée pour l'authentification — local_auth doit rester activé.
  # En prod, l'authentification passe exclusivement par Azure AD.
  local_auth_enabled = var.servicebus_sku == "Premium" ? false : true

  tags = local.common_tags
}

