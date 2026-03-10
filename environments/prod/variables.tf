# ==============================================================================
# Phase 8C - Messaging et Integration
# Environnement : prod
# Fichier : variables.tf
# Description : Déclaration de toutes les variables de l'environnement prod.
#               Les variables sensibles (subscription_id, client_secret, etc.)
#               sont configurées dans TFC — jamais dans terraform.tfvars.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

variable "subscription_id" {
  description = "ID de l'abonnement Azure"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "ID du tenant Azure AD"
  type        = string
  sensitive   = true
}

variable "client_id" {
  description = "App ID du Service Principal Terraform"
  type        = string
  sensitive   = true
}

variable "client_secret" {
  description = "Secret du Service Principal Terraform"
  type        = string
  sensitive   = true
}

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
  default     = "francecentral"
}

variable "vnet_cidr" {
  description = "CIDR du Virtual Network"
  type        = string
}

variable "subnet_bastion_prefix" {
  description = "CIDR du subnet AzureBastionSubnet"
  type        = string
}

variable "subnet_app_prefix" {
  description = "CIDR du subnet snet-app"
  type        = string
}

variable "subnet_monitoring_prefix" {
  description = "CIDR du subnet snet-monitoring"
  type        = string
}

variable "subnet_pe_prefix" {
  description = "CIDR du subnet snet-pe"
  type        = string
}

variable "vm_size_app" {
  description = "Taille de la VM Flask"
  type        = string
}

variable "vm_size_monitoring" {
  description = "Taille de la VM Monitoring"
  type        = string
}

variable "vm_ssh_public_key" {
  description = "Clé publique SSH pour l'accès aux VMs via Azure Bastion"
  type        = string
  sensitive   = true
}

variable "servicebus_sku" {
  description = "SKU du Service Bus Namespace : Standard ou Premium"
  type        = string
}

variable "eventhub_capacity" {
  description = "Nombre de Throughput Units pour le Event Hub Namespace"
  type        = number
}

variable "eventhub_partition_count" {
  description = "Nombre de partitions pour l'Event Hub app-metrics"
  type        = number
}
variable "purge_protection_enabled" {
  description = "Active la protection contre la purge — false en dev/staging, true en prod"
  type        = bool
}

variable "tags" {
  description = "Tags communs appliqués à toutes les ressources"
  type        = map(string)
  default     = {}
}
