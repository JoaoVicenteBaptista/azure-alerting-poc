resource "azurerm_servicebus_namespace" "main" {
  name                = "sb-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"

  tags = local.common_tags
}

resource "azurerm_servicebus_queue" "main" {
  name                = "messages"
  namespace_id        = azurerm_servicebus_namespace.main.id
  max_delivery_count  = 5
  default_message_ttl = "P${var.service_bus_message_ttl_days}D"

  # Dead-lettering settings
  dead_lettering_on_message_expiration = true
}

# Grant Function App's managed identity Azure Service Bus Data Sender role
resource "azurerm_role_assignment" "function_sb_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azapi_resource.main.identity[0].principal_id
}
