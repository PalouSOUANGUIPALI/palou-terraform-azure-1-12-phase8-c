# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : monitoring
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

variable "tags" {
  description = "Tags communs appliqués à toutes les ressources"
  type        = map(string)
  default     = {}
}
