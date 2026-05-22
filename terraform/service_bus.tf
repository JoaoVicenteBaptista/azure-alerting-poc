resource "azurerm_servicebus_namespace" "main" {
  name                = "sb-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_servicebus_queue" "main" {
  name                = "messages"
  namespace_id        = azurerm_servicebus_namespace.main.id
  max_delivery_count  = 5
  default_message_ttl = "P7D"

  # Dead-lettering settings
  dead_lettering_on_message_expiration = true
}
