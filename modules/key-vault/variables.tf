# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : variables.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

variable "project_prefix" {
  description = "Préfixe utilisé pour nommer toutes les ressources"
  type        = string
}

variable "environment" {
  description = "Nom de l'environnement : dev, staging ou prod"
  type        = string
}

variable "location" {
  description = "Région Azure cible"
  type        = string
}

variable "resource_group_name" {
  description = "Nom du Resource Group"
  type        = string
}

variable "purge_protection_enabled" {
  description = "Active la protection contre la purge — true en prod, false en dev/staging"
  type        = bool
  default     = false
}

variable "subnet_pe_id" {
  description = "ID du subnet snet-pe pour le Private Endpoint"
  type        = string
}

variable "private_dns_zone_keyvault_id" {
  description = "ID de la zone DNS privatelink.vaultcore.azure.net"
  type        = string
}

variable "vm_app_identity_principal_id" {
  description = "Principal ID de la Managed Identity de la VM Flask — pour l'attribution RBAC"
  type        = string
}

variable "servicebus_connection_string" {
  description = "Connection string Service Bus — stockée comme secret dans Key Vault"
  type        = string
  sensitive   = true
}

variable "eventhub_connection_string" {
  description = "Connection string Event Hub — stockée comme secret dans Key Vault"
  type        = string
  sensitive   = true
}

variable "log_analytics_workspace_id" {
  description = "ID du Log Analytics Workspace pour les diagnostic settings"
  type        = string
}

variable "tags" {
  description = "Tags communs appliqués à toutes les ressources"
  type        = map(string)
  default     = {}
}
