# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : service-bus
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

variable "servicebus_sku" {
  description = "SKU du Service Bus Namespace : Standard (dev/staging) ou Premium (prod)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.servicebus_sku)
    error_message = "Le SKU doit être Standard ou Premium. Basic ne supporte pas les topics."
  }
}

variable "subnet_pe_id" {
  description = "ID du subnet snet-pe pour le Private Endpoint"
  type        = string
}

variable "private_dns_zone_servicebus_id" {
  description = "ID de la zone DNS privatelink.servicebus.windows.net"
  type        = string
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
