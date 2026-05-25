output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "function_app_name" {
  description = "Function App name"
  value       = azapi_resource.main.name
}

output "function_app_url" {
  description = "Function App base URL"
  value       = "https://${azapi_resource.main.output.properties.defaultHostName}"
}

output "application_insights_connection_string" {
  description = "App Insights connection string"
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "service_bus_namespace" {
  description = "Service Bus namespace FQDN"
  value       = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

output "service_bus_queue_name" {
  description = "Service Bus queue name"
  value       = azurerm_servicebus_queue.main.name
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.main.vault_uri
}
