# ==============================================================================
# Phase 8C - Messaging et Integration
# Module : key-vault
# Fichier : secrets.tf
# Description : Secrets Key Vault — connection strings Service Bus et Event Hub.
#               Ces secrets sont lus par la VM Flask et le consumer
#               via Managed Identity au démarrage. Aucun secret dans le code
#               ni dans les variables Terraform Cloud.
# Auteur : Palou
# Date : Mars 2026
# ==============================================================================

# Connection string Service Bus
# Format : Endpoint=sb://namespace.servicebus.windows.net/;SharedAccessKeyName=...
# Lue par ServiceBusClient dans app/main.py
resource "azurerm_key_vault_secret" "servicebus" {
  name         = "servicebus-connection-string"
  value        = var.servicebus_connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_secrets_officer_tf]

  tags = local.common_tags
}

# Connection string Event Hub
# Format : Endpoint=sb://namespace.servicebus.windows.net/;SharedAccessKeyName=...
# Lue par EventHubProducerClient dans app/main.py
# et par EventHubConsumerClient dans app/consumer.py
resource "azurerm_key_vault_secret" "eventhub" {
  name         = "eventhub-connection-string"
  value        = var.eventhub_connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_secrets_officer_tf]

  tags = local.common_tags
}
