# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : networking
# Fichier : variables.tf
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

variable "project_prefix" {
  description = "Préfixe utilisé pour nommer toutes les ressources (ex: phase8c)"
  type        = string
}

variable "environment" {
  description = "Nom de l'environnement : dev, staging ou prod"
  type        = string
}

variable "location" {
  description = "Région Azure cible"
  type        = string
  default     = "francecentral"
}

variable "vnet_cidr" {
  description = "CIDR du Virtual Network (ex: 10.0.0.0/16)"
  type        = string
}

variable "subnet_bastion_prefix" {
  description = "CIDR du subnet AzureBastionSubnet (minimum /26 requis par Azure)"
  type        = string
}

variable "subnet_app_prefix" {
  description = "CIDR du subnet snet-app (VM Flask + consumer)"
  type        = string
}

variable "subnet_monitoring_prefix" {
  description = "CIDR du subnet snet-monitoring (VM Prometheus / Grafana / Pushgateway)"
  type        = string
}

variable "subnet_pe_prefix" {
  description = "CIDR du subnet snet-pe (Private Endpoints)"
  type        = string
}

variable "tags" {
  description = "Tags communs appliqués à toutes les ressources"
  type        = map(string)
  default     = {}
}
