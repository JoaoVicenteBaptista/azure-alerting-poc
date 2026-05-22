resource "azurerm_storage_account" "function" {
  name                     = "st${replace(var.project_name, "-", "")}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_service_plan" "main" {
  name                = "asp-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Windows"
  sku_name            = "Y1"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_windows_function_app" "main" {
  name                       = "func-${var.project_name}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.function.name
  storage_account_access_key = azurerm_storage_account.function.primary_access_key

  site_config {
    application_stack {
      dotnet_version              = "v10.0"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    "APPLICATIONINSIGHTS_CONNECTION_STRING"         = azurerm_application_insights.main.connection_string
    "APPINSIGHTS_INSTRUMENTATIONKEY"                = azurerm_application_insights.main.instrumentation_key
    "AzureWebJobsStorage"                           = azurerm_storage_account.function.primary_connection_string
    "WEBSITE_RUN_FROM_PACKAGE"                      = "1"
    "ServiceBusConnection__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}
