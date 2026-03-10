# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : event-hub
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

variable "eventhub_capacity" {
  description = "Nombre de Throughput Units (TU) : 2 pour dev/staging, 4 pour prod"
  type        = number
  default     = 2

  validation {
    condition     = var.eventhub_capacity >= 1 && var.eventhub_capacity <= 20
    error_message = "La capacité doit être comprise entre 1 et 20 TU."
  }
}

variable "eventhub_partition_count" {
  description = "Nombre de partitions pour l'Event Hub app-metrics (2 minimum)"
  type        = number
  default     = 2

  validation {
    condition     = contains([2, 4, 8, 16, 32], var.eventhub_partition_count)
    error_message = "Le nombre de partitions doit être 2, 4, 8, 16 ou 32."
  }
}

variable "subnet_pe_id" {
  description = "ID du subnet snet-pe pour le Private Endpoint"
  type        = string
}

variable "private_dns_zone_servicebus_id" {
  description = "ID de la zone DNS privatelink.servicebus.windows.net (partagée avec Service Bus)"
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
