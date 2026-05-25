# Random suffix for global uniqueness
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location

  tags = local.common_tags
}

resource "azurerm_key_vault" "main" {
  name                       = "kv-${var.project_name}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  tags = local.common_tags
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
  ]
}

resource "azurerm_key_vault_secret" "teams_webhook" {
  name         = "teams-webhook-url"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.teams_webhook_url

  depends_on = [azurerm_key_vault_access_policy.terraform]
}
