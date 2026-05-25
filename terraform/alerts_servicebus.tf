# ──────────────────────────────────────────────────────────────
# Service Bus — metric alerts
# ──────────────────────────────────────────────────────────────
# All three alerts are now native metric alerts — no diagnostic
# settings or Log Analytics ingestion needed for Service Bus.

# ────── D1: Aged messages in the working queue ──────
# Catches: consumer is slow or stuck — backlog is accumulating.
# Monitors ActiveMessages averaged over a 15-minute window and splits
# by EntityName so each queue fires independently.
resource "azurerm_monitor_metric_alert" "aged_messages" {
  name                = "alert-sb-aged-messages"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "Active message count sustained above threshold — backlog accumulating. Runbook: ${var.runbook_base_url}/aged-messages"
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT15M"
  enabled             = true

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "ActiveMessages"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.alert_thresholds.active_messages_threshold

    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = ["*"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.warning.id
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/aged-messages" })
}

# ────── D2: DLQ growth ──────
# Catches: any dead-lettered message in any queue. Dimension split on
# EntityName ensures the alert fires per-entity rather than aggregating
# across all queues.
resource "azurerm_monitor_metric_alert" "dlq_growth" {
  name                = "alert-sb-dlq-growth"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "Dead-letter queue has messages — runbook: ${var.runbook_base_url}/dlq-growth"
  severity            = 1
  frequency           = "PT15M"
  window_size         = "PT15M"
  enabled             = true

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = var.alert_thresholds.dlq_growth_delta

    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = ["*"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.critical.id
  }

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/dlq-growth" })
}

# ────── D3: Throttling ──────
# Catches: namespace at tier capacity. Standard SKU caps messaging
# operations per second per messaging unit; throttling is the leading
# indicator that the workload needs to scale to Premium or be sharded.
resource "azurerm_monitor_metric_alert" "sb_throttling" {
  name                = "alert-sb-throttling"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "Service Bus throttled requests in the last 5 minutes — runbook: ${var.runbook_base_url}/sb-throttling"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "ThrottledRequests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.warning.id
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/sb-throttling" })
}
