resource "azurerm_storage_account" "function" {
  name                     = "st${replace(var.project_name, "-", "")}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = local.common_tags
}

resource "azurerm_storage_container" "deployments" {
  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.function.id
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  tags = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  tags = local.common_tags
}

resource "azurerm_service_plan" "main" {
  name                = "asp-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "FC1"

  tags = local.common_tags
}

resource "azapi_resource" "main" {
  type      = "Microsoft.Web/sites@2023-12-01"
  name      = "func-${var.project_name}-${random_string.suffix.result}"
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "functionapp,linux"
    properties = {
      serverFarmId = azurerm_service_plan.main.id
      siteConfig = {
        appSettings = [
          { name = "APPLICATIONINSIGHTS_CONNECTION_STRING", value = azurerm_application_insights.main.connection_string },
          { name = "APPINSIGHTS_INSTRUMENTATIONKEY", value = azurerm_application_insights.main.instrumentation_key },
          { name = "AzureWebJobsStorage__accountName", value = azurerm_storage_account.function.name },
          { name = "ServiceBusConnection__fullyQualifiedNamespace", value = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net" },
        ]
      }
      functionAppConfig = {
        deployment = {
          storage = {
            type  = "blobContainer"
            value = "${azurerm_storage_account.function.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
            authentication = {
              type = "SystemAssignedIdentity"
            }
          }
        }
        scaleAndConcurrency = {
          instanceMemoryMB     = 2048
          maximumInstanceCount = 100
        }
        runtime = {
          name    = "dotnet-isolated"
          version = "10.0"
        }
      }
    }
  }

  response_export_values = ["properties.defaultHostName"]

  tags = local.common_tags
}

# Grant the function app's managed identity the roles it needs to access
# the storage account. Flex Consumption uses identity-based auth instead
# of access keys for triggers, bindings, and runtime state.
resource "azurerm_role_assignment" "function_storage_blob_owner" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azapi_resource.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_storage_queue_contributor" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azapi_resource.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_storage_table_contributor" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azapi_resource.main.identity[0].principal_id
}
