# ──────────────────────────────────────────────────────────────
# Function App / Application Insights — alerts
# ──────────────────────────────────────────────────────────────
#
# Every alert here speaks to a real production failure mode. Each has a
# minimum-traffic floor where it makes statistical sense, an explicit
# auto-mitigation policy, and a runbook tag.

# ────── C1: P95 response time ──────
# Catches: latency regression — slow handler or slow downstream.
# Why KQL not metric: the Microsoft.Web/sites HttpResponseTime metric is the
# AVERAGE response time, not P95. A single 60s outlier moves the average
# almost as much as sustained P95 degradation. App Insights' requests table
# exposes per-request duration, so percentile(duration, 95) gives the real
# signal.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "function_p95_response_time" {
  name                 = "alert-func-p95-response-time"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "P95 response time exceeds ${var.alert_thresholds.p95_response_time_ms}ms — runbook: ${var.runbook_base_url}/p95-regression"
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize p95 = percentile(duration, 95), total = count()
      | where total >= ${var.alert_thresholds.min_request_floor}
      | where p95 > ${var.alert_thresholds.p95_response_time_ms}
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "p95"
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.warning.id]
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/p95-regression" })
}

# ────── C2: Function timeout rate (percentage) ──────
# Catches: handler exceeded the function timeout (hung dependency, deadlock).
# Why % not count: a single timeout during a low-traffic window is noise. 5%
# of traffic timing out is a real degradation.
# total >= 5 floor: avoids divide-by-tiny flapping; the dependency-failure
# alert and request-rate-drop cover the "no traffic" case independently.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "function_timeout_rate" {
  name                 = "alert-func-timeout-rate"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Function timeout rate exceeds ${var.alert_thresholds.timeout_rate_pct}% of requests — runbook: ${var.runbook_base_url}/timeout-rate"
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize total = count(),
                  timeouts = countif(resultCode in ("408", "504") or toint(duration) >= 230000)
      | where total >= ${var.alert_thresholds.min_request_floor}
      | extend pct = 100.0 * timeouts / total
      | where pct > ${var.alert_thresholds.timeout_rate_pct}
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "pct"
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.warning.id]
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/timeout-rate" })
}

# ────── C3: Function failure rate (percentage) ──────
# Catches: HTTP 5xx from the function — user-facing errors.
# Why % not count: identical rationale to C2. auto_mitigation_enabled = false
# so a critical signal does not silently auto-resolve while the underlying
# issue may persist.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "function_failure_rate" {
  name                 = "alert-func-failure-rate"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Function failure rate exceeds ${var.alert_thresholds.failure_rate_pct}% of requests — runbook: ${var.runbook_base_url}/failure-rate"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize total = count(), failed = countif(success == false)
      | where total >= ${var.alert_thresholds.min_request_floor}
      | extend pct = 100.0 * failed / total
      | where pct > ${var.alert_thresholds.failure_rate_pct}
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "pct"
  }

  auto_mitigation_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/failure-rate" })
}

# ────── C4a: Zero-execution heartbeat ──────
# Catches: partial outage, dead worker, broken upstream caller — anything that
# stops the function from executing entirely over a 15-minute window.
# Why KQL over metric: Flex Consumption metric namespaces are not registered
# until the first execution; KQL queries against App Insights `requests` are
# immediately available and cover all invocation types (HTTP + Service Bus).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "execution_heartbeat" {
  name                 = "alert-func-execution-heartbeat"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "No function executions in 15 minutes — runbook: ${var.runbook_base_url}/execution-heartbeat"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(15m)
      | summarize event_count = count()
      | where event_count == 0
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

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/execution-heartbeat" })
}

# ────── C4b: Execution spike ──────
# Catches: traffic significantly above the configured threshold — marketing
# event, scraper, retry storm, runaway client.
# Why Sev 2: spikes are usually benign or self-correcting; they need eyes,
# not a page.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "execution_spike" {
  name                 = "alert-func-execution-spike"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Execution count exceeded ${var.alert_thresholds.execution_spike_threshold} in 15 minutes — runbook: ${var.runbook_base_url}/execution-spike"
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(15m)
      | summarize event_count = count()
      | where event_count > ${var.alert_thresholds.execution_spike_threshold}
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "event_count"
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.warning.id]
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/execution-spike" })
}

# ────── C5: Dependency failure rate ──────
# Catches: outbound call failures the function makes — Service Bus,
# Key Vault, anything else App Insights auto-tracks as a dependency. These
# can be invisible to request-level 5xx metrics if the function swallows
# the exception and returns a degraded 200.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "dependency_failure_rate" {
  name                 = "alert-func-dependency-failure-rate"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Dependency failure rate exceeds ${var.alert_thresholds.dependency_failure_rate_pct}% — runbook: ${var.runbook_base_url}/dependency-failure"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      dependencies
      | where timestamp > ago(5m)
      | summarize total = count(), failed = countif(success == false)
      | where total >= ${var.alert_thresholds.min_request_floor}
      | extend pct = 100.0 * failed / total
      | where pct > ${var.alert_thresholds.dependency_failure_rate_pct}
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "pct"
  }

  auto_mitigation_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/dependency-failure" })
}

# ────── C6: Send-failure spike (structured) ──────
# Catches: Service Bus send failures specifically — bursts of exceptions
# from the messaging client. Filters by exception TYPE (auto-captured by
# App Insights from LogError(ex, ...)) rather than by log-message text,
# which would silently break on a rewording.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "send_failure_spike" {
  name                 = "alert-func-send-failure-spike"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Service Bus exception spike — >${var.alert_thresholds.send_failure_spike_count} in 5 minutes — runbook: ${var.runbook_base_url}/send-failure"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      exceptions
      | where timestamp > ago(5m)
      | where type startswith "Azure.Messaging.ServiceBus"
         or outerType startswith "Azure.Messaging.ServiceBus"
      | summarize event_count = count()
      | where event_count > ${var.alert_thresholds.send_failure_spike_count}
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

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/send-failure" })
}
