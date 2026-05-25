# ──────────────────────────────────────
# Action Groups — severity-routed
# ──────────────────────────────────────
#
# Two groups so Sev 1 and Sev 2 do not share fate. Each receiver list is built
# dynamically from var.notification_emails so the operator can scale recipients
# per environment without editing Terraform.
#
# An alerting-pipeline watchdog is intentionally not implemented here — see the
# "Suggested improvements" section of README.md for the rationale and proposed
# paths to add one.

data "azurerm_key_vault_secret" "teams_webhook" {
  name         = "teams-webhook-url"
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_key_vault_secret.teams_webhook]
}

resource "azurerm_monitor_action_group" "critical" {
  name                = "ag-critical-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "Critical"

  webhook_receiver {
    name                    = "teams-webhook"
    service_uri             = data.azurerm_key_vault_secret.teams_webhook.value
    use_common_alert_schema = true
  }

  dynamic "email_receiver" {
    for_each = var.notification_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags_critical
}

resource "azurerm_monitor_action_group" "warning" {
  name                = "ag-warning-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "Warning"

  webhook_receiver {
    name                    = "teams-webhook"
    service_uri             = data.azurerm_key_vault_secret.teams_webhook.value
    use_common_alert_schema = true
  }

  dynamic "email_receiver" {
    for_each = var.notification_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags_warning
}
