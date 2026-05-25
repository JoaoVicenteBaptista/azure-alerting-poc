# ──────────────────────────────────────────────────────────────
# Infrastructure — Key Vault alerts + supporting diagnostic setting
# ──────────────────────────────────────────────────────────────

# Key Vault audit events are not collected by default. Without this
# setting, the access-failure alert below has nothing to query.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-kv-${var.project_name}"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ────── E1: Key Vault access failures ──────
# Catches: the function, action group, or any other principal that needs
# secrets from this vault has lost permission or hit a network policy.
# Silent here would mean the action group cannot read the webhook secret
# (action groups fail open per receiver — the alert plumbing would still
# attempt delivery, but to a stale or empty URL).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_access_failure" {
  name                 = "alert-kv-access-failure"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_log_analytics_workspace.main.id]
  description          = "Key Vault secret access failure in the last 15 minutes — runbook: ${var.runbook_base_url}/kv-access-failure"
  severity             = 1
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    query = <<-QUERY
      AzureDiagnostics
      | where ResourceProvider == "MICROSOFT.KEYVAULT"
      | where TimeGenerated > ago(15m)
      | where ResultType != "Success"
      | where OperationName in ("SecretGet", "SecretList")
      | summarize event_count = count()
      | where event_count > 0
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "event_count"
  }

  auto_mitigation_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/kv-access-failure" })

  depends_on = [azurerm_monitor_diagnostic_setting.key_vault]
}
