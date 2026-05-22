# ──────────────────────────────────────
# Action Group — Teams webhook receiver
# ──────────────────────────────────────

data "azurerm_key_vault_secret" "teams_webhook" {
  name         = "teams-webhook-url"
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_key_vault_secret.teams_webhook]
}

resource "azurerm_monitor_action_group" "teams" {
  name                = "ag-teams-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "TeamsAlert"

  webhook_receiver {
    name        = "teams-webhook"
    service_uri = data.azurerm_key_vault_secret.teams_webhook.value
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# ──────────────────────────────────────
# Sev 2 — Warning Alerts
# ──────────────────────────────────────

# Alert 1: Function P95 Response Time > 2s
resource "azurerm_monitor_metric_alert" "function_p95_response_time" {
  name                = "alert-func-p95-response-time"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_function_app.main.id]
  description         = "P95 response time exceeds 2 seconds"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "HttpResponseTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 2
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# Alert 2: Function Timeout Rate
resource "azurerm_monitor_metric_alert" "function_timeout_rate" {
  name                = "alert-func-timeout-rate"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_function_app.main.id]
  description         = "Function timeout errors detected"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "FunctionTimeouts"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# Alert 3: Aged Messages in Queue > 300s
resource "azurerm_monitor_metric_alert" "aged_messages" {
  name                = "alert-sb-aged-messages"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "Messages have been in the queue for over 5 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "AverageMessageAge"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 300
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# Alert 4: Request Rate Anomaly (dynamic threshold)
resource "azurerm_monitor_metric_alert" "request_rate_anomaly" {
  name                = "alert-func-request-rate-anomaly"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_function_app.main.id]
  description         = "Anomalous request rate detected"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  dynamic_criteria {
    metric_namespace  = "Microsoft.Web/sites"
    metric_name       = "Requests"
    aggregation       = "Total"
    operator          = "GreaterOrLessThan"
    alert_sensitivity = "High"
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# ──────────────────────────────────────
# Sev 1 — Critical Alerts
# ──────────────────────────────────────

# Alert 5: Function Failure Count
resource "azurerm_monitor_metric_alert" "function_failure_count" {
  name                = "alert-func-failure-count"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_function_app.main.id]
  description         = "Function HTTP failures detected"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "RequestsFailed"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# Alert 6: DLQ Message Count > 0
resource "azurerm_monitor_metric_alert" "dlq_message_count" {
  name                = "alert-sb-dlq-message-count"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "Messages have entered the dead-letter queue"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# Alert 7: DLQ Poison Depth > 3
resource "azurerm_monitor_metric_alert" "dlq_poison_depth" {
  name                = "alert-sb-dlq-poison-depth"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "More than 3 messages in dead-letter queue — possible poison message storm"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 3
  }

  action {
    action_group_id = azurerm_monitor_action_group.teams.id
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# ──────────────────────────────────────
# Log Query Alerts (Sev 1)
# ──────────────────────────────────────

# Alert 8: Send Failure Spike (log-based)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "send_failure_spike" {
  name                 = "alert-func-send-failure-spike"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Send failure spike detected — >2 failures in 5 minutes"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      traces
      | where severityLevel >= 3
      | where message contains "Failed to send"
      | summarize count() by bin(timestamp, 5m)
      QUERY

    time_aggregation_method = "Maximum"
    threshold               = 2
    operator                = "GreaterThan"

    resource_id_column    = "appName"
    metric_measure_column = "count_"
    dimension {
      name     = "appName"
      operator = "Include"
      values   = ["*"]
    }
  }

  auto_mitigation_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.teams.id]
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

# Alert 9: Zero Execution Heartbeat (log-based)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "zero_execution_heartbeat" {
  name                 = "alert-func-zero-execution"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "No requests received in 10 minutes — possible dead function"
  severity             = 1
  evaluation_frequency = "PT10M"
  window_duration      = "PT10M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(10m)
      | summarize count()
      QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "Equal"

    metric_measure_column = "count_"
    dimension {
      name     = "appName"
      operator = "Include"
      values   = ["*"]
    }
  }

  auto_mitigation_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.teams.id]
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}
