# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : compute
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
  description = "Nom du Resource Group dans lequel déployer les VMs"
  type        = string
}

variable "subnet_app_id" {
  description = "ID du subnet snet-app pour la VM Flask"
  type        = string
}

variable "subnet_monitoring_id" {
  description = "ID du subnet snet-monitoring pour la VM Monitoring"
  type        = string
}

variable "vm_size_app" {
  description = "Taille de la VM Flask (ex: Standard_D2s_v6)"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "vm_size_monitoring" {
  description = "Taille de la VM Monitoring (ex: Standard_D2s_v6)"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "vm_ssh_public_key" {
  description = "Clé publique SSH pour l'accès aux VMs via Azure Bastion"
  type        = string
  sensitive   = true
}

variable "key_vault_url" {
  description = "URL du Key Vault — injectée dans le service systemd flask-app via cloud-init"
  type        = string
}

variable "tags" {
  description = "Tags communs appliqués à toutes les ressources"
  type        = map(string)
  default     = {}
}
