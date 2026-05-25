# Production-grade Alerts Implementation Plan

**Status:** Historical — executed with divergences

> **Historical record.** This plan was executed and produced the 11-alert layout now in `main`. The implementation diverged from the design in three areas (see spec note). The as-built state is documented in [`README.md`](../../../README.md).
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the Terraform alerting layer to match the production-grade design at `docs/superpowers/specs/2026-05-24-rate-based-alerts-design.md`, and update the README to reflect the as-built state.

**Architecture:**
- Three severity-routed action groups (critical, warning, watchdog), each with Teams + email or email-only.
- A mix of metric alerts (where pre-aggregated metrics are sufficient) and KQL log-query alerts (for percentages, deltas, and dependency telemetry).
- Diagnostic settings on Service Bus and Key Vault to make their metrics/logs queryable from Log Analytics.
- File split by domain: `alerts.tf` for action groups + watchdog, `alerts_function.tf`, `alerts_servicebus.tf`, `alerts_infra.tf`.

**Tech Stack:** Terraform `~> 1.6`, `azurerm` provider `~> 4.0`, Azure Monitor (metric alerts + scheduled query rules v2), Application Insights, Log Analytics, Service Bus, Key Vault.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `terraform/variables.tf` | modify | Add `notification_emails`, `owner_team`, `runbook_base_url`. |
| `terraform/locals.tf` | **create** | Compose common, critical, warning, informational tag sets. |
| `terraform/terraform.tfvars.example` | modify | Document new variables with sensible placeholders. |
| `terraform/alerts.tf` | **rewrite** | Three action groups + watchdog alert only. |
| `terraform/alerts_function.tf` | **create** | C1–C6 from spec — all function/App Insights alerts. |
| `terraform/alerts_servicebus.tf` | **create** | D1–D3 + Service Bus diagnostic setting. |
| `terraform/alerts_infra.tf` | **create** | E1 + Key Vault diagnostic setting. |
| `README.md` | modify | Replace `## Alerts` section with as-built description and forward-looking limitations. |

Diagnostic settings live with the alerts that consume them (per design section G), not with the resource they observe.

## Order of operations

Each task ends terraform-valid. Resources that change identity (e.g., `azurerm_monitor_metric_alert.function_failure_count` → `azurerm_monitor_scheduled_query_rules_alert_v2.function_failure_rate`) are destroyed and recreated by `terraform apply`; that is acceptable because the stack carries no production traffic.

---

## Task 1: Add new variables, locals, and tfvars.example entries

**Files:**
- Modify: `terraform/variables.tf`
- Create: `terraform/locals.tf`
- Modify: `terraform/terraform.tfvars.example`

- [ ] **Step 1.1: Append the three new variables to `variables.tf`**

Append to `terraform/variables.tf`:

```hcl
variable "notification_emails" {
  description = "Email addresses to notify on alerts. Acts as out-of-band backup to the Teams webhook so a webhook outage does not silence the pipeline."
  type        = list(string)
  default     = []
}

variable "owner_team" {
  description = "Team that owns these resources. Surfaces in tags and alert context."
  type        = string
  default     = "platform"
}

variable "runbook_base_url" {
  description = "Base URL for runbook links embedded in alert descriptions and tags. Per-alert slugs are appended."
  type        = string
  default     = "https://runbooks.example.com/azure-alerting"
}
```

- [ ] **Step 1.2: Create `terraform/locals.tf`**

```hcl
locals {
  common_tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
    owner       = var.owner_team
  }

  tags_critical = merge(local.common_tags, { severity_class = "critical" })
  tags_warning  = merge(local.common_tags, { severity_class = "warning" })
  tags_info     = merge(local.common_tags, { severity_class = "informational" })
}
```

- [ ] **Step 1.3: Extend `terraform.tfvars.example`**

Replace `terraform/terraform.tfvars.example` with:

```hcl
location          = "westeurope"
project_name      = "az-alerting-poc"
environment       = "poc"
teams_webhook_url = "https://your-org.webhook.office.com/webhookb2/..."

# Out-of-band backup channel for alerts. Leave as [] to disable email.
notification_emails = ["oncall@example.com"]

# Team that owns this stack. Surfaces in tags and alert context.
owner_team = "platform"

# Base URL for runbook links. Per-alert slugs are appended.
runbook_base_url = "https://runbooks.example.com/azure-alerting"
```

- [ ] **Step 1.4: Validate**

Run from repo root:

```bash
cd terraform && terraform fmt -check && terraform validate
```

Expected: `Success! The configuration is valid.` `terraform fmt -check` exits 0.

- [ ] **Step 1.5: Commit**

```bash
git add terraform/variables.tf terraform/locals.tf terraform/terraform.tfvars.example
git commit -m "$(cat <<'EOF'
feat(terraform): add notification, owner, and runbook variables

Introduces notification_emails (out-of-band email backup), owner_team,
and runbook_base_url variables consumed by upcoming alert resources,
plus a locals.tf that composes the common/critical/warning/info tag
sets.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Action groups rework + watchdog alert

Replace the single `ag-teams-*` action group with three severity-routed groups and add the watchdog heartbeat alert. The existing alerts in `alerts.tf` still reference `azurerm_monitor_action_group.teams`, so we update each reference in this same task to keep the apply valid.

**Files:**
- Modify: `terraform/alerts.tf` (full rewrite of action-group block; update every alert's `action_group_id` / `action_groups`)

- [ ] **Step 2.1: Rewrite `terraform/alerts.tf` from the top through the action-group section**

Replace the top of the file (lines 1–31, the existing action group + data source) with:

```hcl
# ──────────────────────────────────────
# Action Groups — severity-routed
# ──────────────────────────────────────
#
# Three groups instead of one so Sev 1 and Sev 2 do not share fate, and so the
# watchdog (which exists to detect a broken alerting pipeline) does not depend
# on the same Teams webhook it is meant to check.
#
# Each receiver list is built dynamically from var.notification_emails so the
# operator can scale recipients per environment without editing Terraform.

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

# Watchdog AG intentionally has NO webhook receiver — if the Teams webhook is
# the thing that broke, the watchdog must use an independent channel.
resource "azurerm_monitor_action_group" "watchdog" {
  name                = "ag-watchdog-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "Watchdog"

  dynamic "email_receiver" {
    for_each = var.notification_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags_info
}

# ──────────────────────────────────────
# Watchdog — heartbeat that fires hourly
# ──────────────────────────────────────
#
# If operators stop receiving this hourly informational email, the alerting
# pipeline is broken. Crude in-Azure mechanism; a proper external dead-man's
# switch (Healthchecks.io / PagerDuty heartbeat) is the next maturity step.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "alerting_watchdog" {
  name                 = "alert-watchdog-heartbeat"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_application_insights.main.id]
  description          = "Alerting pipeline heartbeat — absence means alerts are broken — runbook: ${var.runbook_base_url}/watchdog"
  severity             = 4
  evaluation_frequency = "PT1H"
  window_duration      = "PT1H"

  criteria {
    query                   = "print heartbeat = 1 | where heartbeat == 1"
    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "heartbeat"
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.watchdog.id]
  }

  tags = merge(local.tags_info, { runbook = "${var.runbook_base_url}/watchdog" })
}
```

- [ ] **Step 2.2: Update every existing alert's action-group reference in `alerts.tf`**

For each existing alert below the action-group section, change:

- Sev 1 alerts (`function_failure_count`, `dlq_message_count`, `send_failure_spike`, `zero_execution_heartbeat`):
  - `action_group_id = azurerm_monitor_action_group.teams.id` → `action_group_id = azurerm_monitor_action_group.critical.id`
  - `action_groups = [azurerm_monitor_action_group.teams.id]` → `action_groups = [azurerm_monitor_action_group.critical.id]`

- Sev 2 alerts (`function_p95_response_time`, `function_timeout_rate`, `aged_messages`, `request_rate_anomaly`):
  - same swap, but to `azurerm_monitor_action_group.warning.id`.

These existing alerts are deleted in later tasks; the swap keeps `terraform plan` valid in the meantime.

- [ ] **Step 2.3: Validate**

```bash
cd terraform && terraform fmt -check && terraform validate
```

Expected: success.

- [ ] **Step 2.4: Commit**

```bash
git add terraform/alerts.tf
git commit -m "$(cat <<'EOF'
feat(alerts): split action groups by severity and add watchdog

Replace single ag-teams with ag-critical, ag-warning, and ag-watchdog.
Critical and warning receive Teams + email; watchdog is email-only so it
cannot share fate with the channel it monitors. Add Sev 4 hourly
heartbeat alert routed to the watchdog group — absence of heartbeat
indicates the alerting pipeline is broken.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Function alerts — create `alerts_function.tf`, remove old function alerts from `alerts.tf`

**Files:**
- Create: `terraform/alerts_function.tf`
- Modify: `terraform/alerts.tf` (delete the four function-app alerts: P95, timeout, request-rate-anomaly, failure-count; delete the zero-execution log alert; delete the send-failure log alert — they are all replaced or removed in this task)

- [ ] **Step 3.1: Create `terraform/alerts_function.tf` with the full rewritten function-domain alerts**

```hcl
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
  description          = "P95 response time exceeds 2s — runbook: ${var.runbook_base_url}/p95-regression"
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize p95 = percentile(duration, 95), total = count()
      | where total >= 5
      | where p95 > 2000
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
  description          = "Function timeout rate exceeds 5% of requests — runbook: ${var.runbook_base_url}/timeout-rate"
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize total = count(),
                  timeouts = countif(resultCode in ("408", "504") or toint(duration) >= 230000)
      | where total >= 5
      | extend pct = 100.0 * timeouts / total
      | where pct > 5
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
  description          = "Function failure rate exceeds 5% of requests — runbook: ${var.runbook_base_url}/failure-rate"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      requests
      | where timestamp > ago(5m)
      | summarize total = count(), failed = countif(success == false)
      | where total >= 5
      | extend pct = 100.0 * failed / total
      | where pct > 5
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

# ────── C4a: Request rate drop ──────
# Catches: partial outage, dead worker, broken upstream caller — anything that
# pulls traffic significantly below the learned baseline.
# Why Medium sensitivity: Azure documents High as for testing; Medium is the
# production default and tolerates normal traffic variance.
# Why Sev 1: a sustained traffic drop usually means the service is degraded
# or dead. Subsumes the old zero_execution_heartbeat strict count==0 check
# without flapping on naturally quiet windows.
resource "azurerm_monitor_metric_alert" "request_rate_drop" {
  name                = "alert-func-request-rate-drop"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_function_app.main.id]
  description         = "Request rate dropped significantly below baseline — runbook: ${var.runbook_base_url}/request-rate-drop"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  dynamic_criteria {
    metric_namespace  = "Microsoft.Web/sites"
    metric_name       = "Requests"
    aggregation       = "Total"
    operator          = "LessThan"
    alert_sensitivity = "Medium"
  }

  action {
    action_group_id = azurerm_monitor_action_group.critical.id
  }

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/request-rate-drop" })
}

# ────── C4b: Request rate spike ──────
# Catches: traffic significantly above the learned baseline — marketing
# event, scraper, retry storm, runaway client.
# Why Sev 2: spikes are usually benign or self-correcting; they need eyes,
# not a page.
resource "azurerm_monitor_metric_alert" "request_rate_spike" {
  name                = "alert-func-request-rate-spike"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_function_app.main.id]
  description         = "Request rate spiked significantly above baseline — runbook: ${var.runbook_base_url}/request-rate-spike"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  dynamic_criteria {
    metric_namespace  = "Microsoft.Web/sites"
    metric_name       = "Requests"
    aggregation       = "Total"
    operator          = "GreaterThan"
    alert_sensitivity = "Medium"
  }

  action {
    action_group_id = azurerm_monitor_action_group.warning.id
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/request-rate-spike" })
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
  description          = "Dependency failure rate exceeds 5% — runbook: ${var.runbook_base_url}/dependency-failure"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query = <<-QUERY
      dependencies
      | where timestamp > ago(5m)
      | summarize total = count(), failed = countif(success == false)
      | where total >= 5
      | extend pct = 100.0 * failed / total
      | where pct > 5
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
  description          = "Service Bus exception spike — >2 in 5 minutes — runbook: ${var.runbook_base_url}/send-failure"
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
      | where event_count > 2
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
```

- [ ] **Step 3.2: Delete the obsolete function alerts from `terraform/alerts.tf`**

Remove from `alerts.tf` (the file now only contains the action-group + watchdog section from Task 2):

- `azurerm_monitor_metric_alert.function_p95_response_time` (replaced by C1 above)
- `azurerm_monitor_metric_alert.function_timeout_rate` (replaced by C2)
- `azurerm_monitor_metric_alert.function_failure_count` (replaced by C3, also renamed)
- `azurerm_monitor_metric_alert.request_rate_anomaly` (split into C4a/C4b)
- `azurerm_monitor_scheduled_query_rules_alert_v2.send_failure_spike` (replaced by C6 above; same name)
- `azurerm_monitor_scheduled_query_rules_alert_v2.zero_execution_heartbeat` (removed entirely — subsumed by C4a)

Service-Bus alerts (`aged_messages`, `dlq_message_count`) are NOT removed in this task — they move in Task 4.

- [ ] **Step 3.3: Validate**

```bash
cd terraform && terraform fmt -check && terraform validate
```

Expected: success. `terraform plan` (if state exists) would show ~5 destroys and ~7 creates in the function domain.

- [ ] **Step 3.4: Commit**

```bash
git add terraform/alerts_function.tf terraform/alerts.tf
git commit -m "$(cat <<'EOF'
feat(alerts): rewrite function alerts to production-grade

- function_p95_response_time: switch from average HttpResponseTime metric
  to App Insights percentile(duration, 95). Old alert was misnamed.
- function_timeout_rate / function_failure_rate: KQL percentage alerts
  with total >= 5 floor; replace > 0 demo thresholds.
- request_rate_anomaly: split into request_rate_drop (Sev 1) and
  request_rate_spike (Sev 2), both Medium sensitivity.
- zero_execution_heartbeat: removed; subsumed by request_rate_drop.
- dependency_failure_rate: new — catches Service Bus / Key Vault call
  failures invisible to request 5xx.
- send_failure_spike: switch from log-message-text match to exception
  type filter on Azure.Messaging.ServiceBus.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Service Bus alerts — create `alerts_servicebus.tf`, remove old SB alerts from `alerts.tf`

**Files:**
- Create: `terraform/alerts_servicebus.tf`
- Modify: `terraform/alerts.tf` (delete `aged_messages` and `dlq_message_count`)

- [ ] **Step 4.1: Create `terraform/alerts_servicebus.tf`**

```hcl
# ──────────────────────────────────────────────────────────────
# Service Bus — alerts and supporting diagnostic setting
# ──────────────────────────────────────────────────────────────

# Ship Service Bus metrics to Log Analytics so the DLQ-growth KQL alert
# (D2) can compute deltas across windows. AllMetrics is enabled because
# DeadletteredMessages, ThrottledRequests, and AverageMessageAge all live
# under this category and are cheap to ingest at PoC volume.
resource "azurerm_monitor_diagnostic_setting" "service_bus" {
  name                       = "diag-sb-${var.project_name}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_metric {
    category = "AllMetrics"
  }
}

# ────── D1: Aged messages in the working queue ──────
# Catches: consumer is slow or stuck — backlog is accumulating.
# Why EntityName dimension: AverageMessageAge is averaged across all
# entities in the namespace; without filtering, a second healthy queue
# would mask backlog on this one.
resource "azurerm_monitor_metric_alert" "aged_messages" {
  name                = "alert-sb-aged-messages"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_servicebus_namespace.main.id]
  description         = "Messages have been queued for over 5 minutes — runbook: ${var.runbook_base_url}/aged-messages"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "AverageMessageAge"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 300

    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = [azurerm_servicebus_queue.main.name]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.warning.id
  }

  tags = merge(local.tags_warning, { runbook = "${var.runbook_base_url}/aged-messages" })
}

# ────── D2: DLQ growth (delta) ──────
# Catches: new poison messages arriving — not just the first occurrence.
# Why KQL not metric: DeadletteredMessages is a gauge of current depth.
# A metric alert fires once on first arrival and stays in the same
# instance until the DLQ is drained; it cannot detect ongoing growth.
# max - min over the window gives net growth; negative deltas (operator
# draining the DLQ) are intentionally ignored.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "dlq_growth" {
  name                 = "alert-sb-dlq-growth"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  scopes               = [azurerm_log_analytics_workspace.main.id]
  description          = "Dead-letter queue grew within the last 10 minutes — runbook: ${var.runbook_base_url}/dlq-growth"
  severity             = 1
  evaluation_frequency = "PT10M"
  window_duration      = "PT10M"

  criteria {
    query = <<-QUERY
      AzureMetrics
      | where ResourceId has "/providers/Microsoft.ServiceBus/namespaces/"
      | where MetricName == "DeadletteredMessages"
      | where TimeGenerated > ago(10m)
      | summarize delta = max(Maximum) - min(Maximum)
      | where delta > 0
    QUERY

    time_aggregation_method = "Maximum"
    threshold               = 0
    operator                = "GreaterThan"
    metric_measure_column   = "delta"
  }

  auto_mitigation_enabled = false

  action {
    action_groups = [azurerm_monitor_action_group.critical.id]
  }

  tags = merge(local.tags_critical, { runbook = "${var.runbook_base_url}/dlq-growth" })

  depends_on = [azurerm_monitor_diagnostic_setting.service_bus]
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
```

- [ ] **Step 4.2: Delete `aged_messages` and `dlq_message_count` from `terraform/alerts.tf`**

Remove the two `azurerm_monitor_metric_alert` blocks for `aged_messages` and `dlq_message_count`. After this step, `alerts.tf` contains only: the `data` block for the Teams webhook, the three action groups, and the watchdog alert.

- [ ] **Step 4.3: Validate**

```bash
cd terraform && terraform fmt -check && terraform validate
```

Expected: success.

- [ ] **Step 4.4: Commit**

```bash
git add terraform/alerts_servicebus.tf terraform/alerts.tf
git commit -m "$(cat <<'EOF'
feat(alerts): rewrite Service Bus alerts to production-grade

- Diagnostic setting on the Service Bus namespace ships AllMetrics to
  Log Analytics so KQL can compute deltas.
- aged_messages: add EntityName dimension so per-queue health is not
  averaged out by other entities.
- dlq_growth: replaces dlq_message_count. KQL delta on
  DeadletteredMessages so the alert keeps firing as the DLQ grows
  instead of going silent after the first message.
- sb_throttling: new — leading indicator of Standard SKU capacity.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Infrastructure alerts — create `alerts_infra.tf`

**Files:**
- Create: `terraform/alerts_infra.tf`

- [ ] **Step 5.1: Create `terraform/alerts_infra.tf`**

```hcl
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
```

- [ ] **Step 5.2: Validate**

```bash
cd terraform && terraform fmt -check && terraform validate
```

Expected: success.

- [ ] **Step 5.3: Commit**

```bash
git add terraform/alerts_infra.tf
git commit -m "$(cat <<'EOF'
feat(alerts): add Key Vault access-failure alert

Adds Key Vault diagnostic setting (AuditEvent + AllMetrics → Log
Analytics) and a Sev 1 KQL alert on SecretGet/SecretList failures.
Closes the silent-failure gap where the action group could not read
the Teams webhook secret without anyone noticing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final terraform validation pass

**Files:** none modified.

- [ ] **Step 6.1: Format, validate, and plan**

From the repo root (PowerShell):

```powershell
cd terraform
terraform fmt
terraform validate
terraform plan -out alerting.tfplan
```

Expected: `terraform validate` reports `Success! The configuration is valid.`. `terraform plan` lists destroys for the obsolete resources (`function_p95_response_time` as metric alert, `function_failure_count`, `dlq_message_count`, `zero_execution_heartbeat`, `request_rate_anomaly`, `function_timeout_rate` as metric alert, original `ag-teams`, original `send_failure_spike`) and creates for all replacements plus the new resources. No syntax or reference errors. Delete `alerting.tfplan` after inspection.

- [ ] **Step 6.2: Confirm new resource counts**

Use the Grep tool (or PowerShell `Select-String -Pattern "^resource " -Path terraform\alerts*.tf | Group-Object Path | Select Name, Count`):

Expected:
- `alerts.tf`: 4 (3 action groups + watchdog)
- `alerts_function.tf`: 7 (C1–C6 with C4 split into 4a/4b)
- `alerts_servicebus.tf`: 4 (diag setting + D1 + D2 + D3)
- `alerts_infra.tf`: 2 (diag setting + E1)

Total alert/AG/diag resources: 17. Removed from old state: 9 (8 alerts + 1 old AG). Net add: ~8.

- [ ] **Step 6.3: Commit any formatting changes**

If `terraform fmt` rewrote anything:

```bash
git add terraform/
git commit -m "$(cat <<'EOF'
chore(terraform): apply terraform fmt

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If nothing changed, skip this commit.

---

## Task 7: Update README.md to reflect the as-built production-grade state

**Files:**
- Modify: `README.md`

The current README has a `## Alerts` section that documents the OLD 8-alert layout and lists 10 known limitations. After this task it documents the new 13-alert layout with limitations limited to genuine open items.

- [ ] **Step 7.1: Replace the `## Alerts` section in `README.md`**

Locate the `## Alerts` section header in `README.md`. Replace everything from that header down to (but not including) the next `## ` heading or end-of-file with:

````markdown
## Alerts

Thirteen alerts ship across three severity tiers, routed by severity to three Azure Monitor action groups. Sev 1 and Sev 2 use Teams + email; the Sev 4 watchdog uses email only so it does not share fate with the channel it is checking.

### Severity model

- **Sev 1 — Critical:** user-impacting or data-at-risk. Page-now in a real on-call setup. `auto_mitigation_enabled = false` — stays open until acknowledged.
- **Sev 2 — Warning:** degraded behaviour or anomalous traffic. Investigate during business hours. Auto-resolves when conditions clear.
- **Sev 4 — Informational:** the watchdog heartbeat. Absence of these hourly emails means the alerting pipeline itself is broken.

### Action groups

| Group | Receivers | Used by |
|---|---|---|
| `ag-critical-${project}` | Teams webhook + every address in `notification_emails` | Sev 1 alerts |
| `ag-warning-${project}` | Teams webhook + every address in `notification_emails` | Sev 2 alerts |
| `ag-watchdog-${project}` | every address in `notification_emails` (no webhook) | Sev 4 watchdog only |

Both real-alert groups use the common alert schema (`use_common_alert_schema = true`) so metric and log alerts arrive in the same payload shape.

### Sev 1 — Critical

| Alert | Type | Signal | What it tells you |
|---|---|---|---|
| `function_failure_rate` | KQL on App Insights `requests` | failure % > 5% with total ≥ 5 over 5m | User-facing 5xx is a real fraction of traffic. |
| `request_rate_drop` | Metric, dynamic threshold | `Requests` LessThan Medium baseline over 15m | Service is significantly below its learned traffic baseline — likely degraded or dead. |
| `dependency_failure_rate` | KQL on App Insights `dependencies` | dep-failure % > 5% with total ≥ 5 over 5m | Outbound calls (Service Bus, Key Vault, etc.) are failing — even if requests still return 200. |
| `send_failure_spike` | KQL on App Insights `exceptions` | `Azure.Messaging.ServiceBus*` exception count > 2 in 5m | Burst of messaging-client exceptions — the queue path is broken. Filters by exception type, not log text. |
| `dlq_growth` | KQL on `AzureMetrics` | `max(DeadletteredMessages) - min(...)` > 0 over 10m | New poison messages are arriving — fires repeatedly per window, not just once. |
| `kv_access_failure` | KQL on `AzureDiagnostics` | `SecretGet`/`SecretList` failures > 0 over 15m | Secret reads are failing — would silently break the action group's webhook lookup. |

### Sev 2 — Warning

| Alert | Type | Signal | What it tells you |
|---|---|---|---|
| `function_p95_response_time` | KQL on App Insights `requests` | `percentile(duration, 95) > 2000ms` with total ≥ 5 over 5m | P95 latency regression. Genuinely measures P95 (the metric-based alert that used average response time has been replaced). |
| `function_timeout_rate` | KQL on App Insights `requests` | timeout % (resultCode 408/504 or duration ≥ 230s) > 5% over 5m | Handler timeouts are a real fraction of traffic. |
| `request_rate_spike` | Metric, dynamic threshold | `Requests` GreaterThan Medium baseline over 15m | Traffic significantly above baseline — marketing event, scraper, retry storm. |
| `aged_messages` | Metric, scoped to `messages` queue | `AverageMessageAge` > 300s over 5m | Consumer is slow or stuck for this specific queue (filtered by `EntityName` so other queues can't mask it). |
| `sb_throttling` | Metric | `ThrottledRequests` > 0 over 5m | Service Bus namespace is at tier capacity. Leading indicator to scale to Premium. |

### Sev 4 — Watchdog

| Alert | Type | Signal | What it tells you |
|---|---|---|---|
| `alerting_watchdog` | KQL heartbeat | hourly synthetic event | The alerting pipeline is alive. Absence of hourly emails means it isn't. |

### Design rationale

- **Why both metric and log alerts.** Platform metrics (Azure Monitor) are cheap, fast, and pre-aggregated, but they can't detect *absence* of data, can't filter on log content, and can't divide one signal by another. KQL log-query alerts cover those cases — percentages of total traffic, deltas across windows, exception-type filtering, audit-log queries. Each alert is on the cheapest tool that can actually answer the question.
- **Why three action groups instead of one.** A single webhook is a single point of failure: a webhook rotation, Teams outage, or secret-retrieval failure silences every alert at once. Splitting by severity decouples Sev 1 routing from Sev 2 noise and lets the watchdog use an independent channel. Email is the out-of-band backup so a webhook failure does not blind the operator.
- **Why percentage rates, not counts.** A single failed request, single timeout, or single DLQ entry is noise at production traffic levels. Alerts fire on *sustained* fractions of traffic (5% with a `total >= 5` floor for the request-side alerts) so single events don't page.
- **Why `auto_mitigation_enabled = false` on every Sev 1 KQL alert.** Critical signals should not silently auto-resolve while the underlying issue may persist. An operator acknowledges them. Metric alerts auto-resolve when criteria clear — they do not support this setting.
- **Why `EntityName` dimension on `aged_messages`.** `AverageMessageAge` is averaged across all entities in the namespace. Filtering to a specific queue prevents a healthy entity from masking backlog on another.
- **Why exception-type filter for `send_failure_spike`.** The previous implementation matched `message contains "Failed to send"`. A future log-message reword would silently break the alert. Filtering by exception `type` (auto-captured by App Insights from `LogError(ex, ...)`) survives log rewrites.

### Diagnostic settings

Two non-default diagnostic settings ship the data the KQL alerts depend on:

- `diag-sb-${project}` — Service Bus `AllMetrics` → Log Analytics (powers `dlq_growth`).
- `diag-kv-${project}` — Key Vault `AuditEvent` + `AllMetrics` → Log Analytics (powers `kv_access_failure`).

### Tagging

Every alert and action group carries:

- `environment`, `project`, `cost-center` — pre-existing taxonomy.
- `owner` — from `var.owner_team`. Used to route on-call ownership.
- `severity_class` — `critical`, `warning`, or `informational`. Used by alert-processing rules.
- `runbook` — per-alert URL under `var.runbook_base_url`. Surfaces the operator runbook directly from the alert.

### Known limitations

These are genuine open items, not shortcuts:

- **In-Azure watchdog only.** The hourly heartbeat detects when Azure Monitor stops firing scheduled queries, but it cannot detect a regional outage or a subscription-level monitoring failure. A proper external dead-man's switch (Healthchecks.io, PagerDuty heartbeat, or a separate cloud) is the next maturity step.
- **Runbooks are placeholders.** URLs in alert descriptions point at `var.runbook_base_url` (default `https://runbooks.example.com/azure-alerting`). Actual runbook content is a separate workstream.
- **No SLO / burn-rate alerts.** Multi-window error-budget burn alerts (e.g., 2% / 1h and 5% / 6h on a 99.9% target) replace static thresholds with something tied to a real availability commitment. The file layout supports adding them in `alerts_function.tf` without restructuring.
- **No alert-processing rules.** Maintenance-window suppression and on-call routing rules are not configured; planned deploys will fire spurious alerts until added.
- **Thresholds are first-principles.** `5%`, `total >= 5`, `delta > 0`, anomaly `Medium` sensitivity, and the 15m / 10m / 5m windows are all initial guesses. Tune against real traffic once it exists.

````

- [ ] **Step 7.2: Update the line in the README that summarises the alert count**

Find the line near the top of the README:

```
- **Alerting** — 8 alerts (metric + log query) via Azure Monitor → Action Group → Teams webhook
```

Replace with:

```
- **Alerting** — 13 alerts across 3 severity tiers, routed via 3 severity-split action groups to Teams + email
```

- [ ] **Step 7.3: Update the "Resources Created" bullet**

Find in the `## Resources Created` section:

```
- Action Group (Teams webhook)
- 8 Metric/Log Alerts (see [Alerts](#alerts))
```

Replace with:

```
- 3 Action Groups (critical, warning, watchdog)
- 2 Diagnostic Settings (Service Bus, Key Vault → Log Analytics)
- 13 Metric/Log Alerts (see [Alerts](#alerts))
```

- [ ] **Step 7.4: Update the project structure tree in the README**

Find the `terraform/` section in the `Project Structure` tree and update from:

```
├── terraform/
│   ├── providers.tf
│   ├── variables.tf
│   ├── key_vault.tf
│   ├── function_app.tf
│   ├── service_bus.tf
│   ├── alerts.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
```

to:

```
├── terraform/
│   ├── providers.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── key_vault.tf
│   ├── function_app.tf
│   ├── service_bus.tf
│   ├── alerts.tf              # action groups + watchdog
│   ├── alerts_function.tf     # function / App Insights alerts
│   ├── alerts_servicebus.tf   # Service Bus alerts + diag setting
│   ├── alerts_infra.tf        # Key Vault alert + diag setting
│   ├── outputs.tf
│   └── terraform.tfvars.example
```

- [ ] **Step 7.5: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): replace alert documentation with as-built description

Replaces the old 8-alert demo description and its 10-item limitations
list with documentation of the 13 alerts now shipped, three action
groups, two diagnostic settings, and tagging conventions. Limitations
section is reduced to genuine open items (external watchdog, runbook
content, SLO/burn-rate alerts, alert-processing rules, threshold
tuning).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist

After all tasks land:

- [ ] Spec coverage:
  - [ ] A1–A3 action groups: Task 2 ✓
  - [ ] B1 watchdog: Task 2 ✓
  - [ ] C1 P95 fix: Task 3 ✓
  - [ ] C2 timeout rate: Task 3 ✓
  - [ ] C3 failure rate: Task 3 ✓
  - [ ] C4a/C4b rate drop / spike split: Task 3 ✓
  - [ ] C5 dependency failure: Task 3 ✓
  - [ ] C6 structured send-failure filter: Task 3 ✓
  - [ ] D1 aged_messages entity filter: Task 4 ✓
  - [ ] D2a SB diag setting + D2b DLQ delta: Task 4 ✓
  - [ ] D3 sb throttling: Task 4 ✓
  - [ ] E1a KV diag setting + E1b KV access failure: Task 5 ✓
  - [ ] F1 new variables: Task 1 ✓
  - [ ] F2 tagging: Tasks 1 (locals) + 2–5 (per-resource use) ✓
  - [ ] F3 runbook URLs in descriptions: Tasks 2–5 ✓
  - [ ] F4 explicit auto_mitigation on KQL alerts: Tasks 2–5 ✓
  - [ ] G file layout: Tasks 2–5 ✓
- [ ] README accuracy: Task 7 ✓
- [ ] Removed obsolete: `zero_execution_heartbeat`, `function_failure_count`, `dlq_message_count`, original `request_rate_anomaly`, original `function_p95_response_time` (metric alert), original `function_timeout_rate` (metric alert), original `ag-teams` action group — all destroyed in the apply implied by Tasks 3–4.

## Out of scope (deferred follow-ups)

- External dead-man's switch (Healthchecks.io / PagerDuty heartbeat).
- SLO / multi-window burn-rate alerts.
- Alert-processing rules for maintenance-window suppression and severity routing.
- Runbook content (URLs in descriptions are placeholders pointing at `var.runbook_base_url`).
- Tagging existing non-alert resources (function app, KV, SB, storage) with `owner` / `team`. Scope here is alerting; broader retag is a separate change.
- `subscription_id` pinning in `providers.tf`.
- App Insights sampling tuning.
- Function App `health_check_path`.
