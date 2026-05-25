# Production-grade Alerting — Design

**Status:** Design — implementation diverged

> **Note.** This design was largely implemented but diverged in three areas during execution:
> - **Watchdog (section B) removed.** Its synthetic query stayed permanently in "firing" state and the dedicated action group it used was not worth the operator noise. See README "Suggested improvements" for replacement options.
> - **C4a/C4b replaced.** `request_rate_drop` and `request_rate_spike` (dynamic metric alerts) became `execution_heartbeat` and `execution_spike` (KQL on `requests`) because Flex Consumption metric namespaces aren't registered until first execution.
> - **3 action groups → 2.** `ag-watchdog` was removed along with the watchdog, leaving `ag-critical` and `ag-warning`.

**Date:** 2026-05-24
**Scope:** Rework `terraform/alerts.tf` and supporting infrastructure so the alerting layer is a defensible base for a production system. Covers conversion of demo-grade count alerts to rate-based equivalents, fixes for factual bugs, notification-path hardening, missing coverage, and hygiene.

This design supersedes the earlier "rate-based alerts" scope after a full review.

## Background

The existing alerts work as a demo but are not safe to inherit into production:

- One alert (`function_p95_response_time`) measures average response time but is named "P95" — its behaviour does not match its label.
- Three alerts (`function_timeout_rate`, `function_failure_count`, `dlq_message_count`) page on single events; production traffic produces single events constantly.
- The notification path is a single Teams webhook; if it fails or rotates, every alert silently disappears. There is no out-of-band channel and no watchdog.
- Several alerts use fragile inputs: free-text log-message matching, the "High" anomaly-detection sensitivity (which Azure documents as for testing), namespace-wide queue scopes, and a strict `count() == 0` heartbeat that flaps on naturally quiet services.
- Coverage gaps: no Service Bus throttling alert, no dependency-failure detection, no Key Vault access-failure alert.
- Hygiene gaps: tags lack owner/team/runbook metadata; descriptions don't link runbooks; all alerts live in one file.

## Goals

- Every alert is **actionable**: maps to a real failure mode with a runbook entry.
- Every alert is **honest**: name and description describe what it actually fires on.
- **No single point of failure** in the notification path.
- **Severity-appropriate routing**: Sev 1 and Sev 2 do not share fate.
- **Self-monitoring**: a watchdog signal exists for the alerting pipeline.
- **Production hygiene**: structured tags, runbook links, sensible file layout, explicit auto-mitigation.

## Non-goals

- Building external dead-man's-switch infrastructure (Healthchecks.io, PagerDuty heartbeat). The watchdog stays in-Azure for now; documented as a known limitation.
- Tuning thresholds against real traffic data. Initial values are first-principles; operators will adjust.
- SLO-based alerting (burn-rate alerts on error budgets). Out of scope for this iteration but the file layout below makes it straightforward to add later.

## Assumptions

This design operates under the following assumptions. If any of these change, the design should be revisited.

### Structured logging

The function emits **structured logs** — every log entry has a consistent schema with named properties rather than relying on free-text message parsing. Concretely:

- App Insights `traces` table entries carry `CorrelationId`, `BodySize`, `MessageId`, and `Source` as first-class custom dimensions, not as embedded fragments inside a `message` string.
- KQL alerts query these dimensions directly (e.g., `| where customDimensions.Source == "az-alerting"`) rather than using `message contains` or regex extraction.
- New log entries added in the future must follow the same pattern: add custom dimensions for any machine-actionable field; the `message` field is human-readable but is **not** relied on for alerting.

This assumption is already true of the current code (`LogInformation` with structured placeholders + `LogError` with exception type capture) but is called out here because it underpins every KQL alert in this design. A move to unstructured logging (e.g., raw string interpolation into a single `message` string) would break every log-based alert silently.

### Log data-plane is App Insights (not Log Analytics custom tables)

All KQL alerts query App Insights tables (`requests`, `dependencies`, `exceptions`, `traces`). There is no assumption that the function writes to Log Analytics custom tables (`AzureDiagnostics` is only used for the Key Vault alert, which is the platform's own diagnostic data). If the function grows to emit custom log schemas directly to Log Analytics, alert queries need to move to the appropriate table.

### Single-function, single-queue

The alerting design assumes one HTTP-triggered function posting to one Service Bus queue. Adding a second function or a second queue requires: (a) new entity-level dimension filters on Service Bus metric alerts, and (b) new `cloud_RoleName` filters on function-side KQL alerts to prevent a noisy neighbour from masking the original function's metrics.

### Callers are trusted (within a bounded context)

The function does not validate or sanitize the request body beyond ensuring it is valid JSON. It assumes callers are known services within the same system. A public-facing or multi-tenant function would need:

- Request body validation and size enforcement.
- Rate limiting.
- PII redaction before logging or telemetry (see README "Compliance and governance" for the current posture).

---

## Design

### A. Action groups (notification path)

Replace the single `ag-teams-*` action group with **three action groups** — two by severity for real alerts, and a third dedicated to the watchdog (see section B):

| Action group | Purpose | Receivers |
|---|---|---|
| `ag-critical-${project}` | Sev 1 routing | Teams webhook + email list |
| `ag-warning-${project}` | Sev 2 routing | Teams webhook + email list |
| `ag-watchdog-${project}` | Sev 4 watchdog only (B) | email list only |

The two real-alert groups receive the same Teams webhook (already secret-backed via Key Vault) **and** an `email_receiver` per address in a new `notification_emails` variable. Email is the out-of-band channel: if the Teams webhook fails, email still arrives.

Rationale for two groups instead of one:

- Lets future alert-processing rules (suppression during maintenance, working-hours routing) target Sev 2 without affecting Sev 1.
- Decouples on-call rotation routing (typically only Sev 1) from informational/warning channels.

`short_name` values: `Critical` and `Warning`.

### B. Watchdog

Add `azurerm_monitor_scheduled_query_rules_alert_v2.alerting_watchdog`:

```kql
print heartbeat = 1
| where heartbeat == 1
```

- Sev 4 (informational).
- Evaluation frequency 1h, window 1h.
- Routed to the `ag-watchdog-${project}` action group (A3) whose only receiver is the email list. (Watchdog must not depend on the Teams webhook — that's one of the things we're checking.)
- Operators expect one heartbeat email per hour. Absence of heartbeat means the alerting pipeline itself is broken.

This is a crude in-Azure watchdog; documented as such. The proper fix (external dead-man's switch) is called out in the README as a follow-up.

### C. Function alerts (Microsoft.Web/sites + App Insights)

Move to `terraform/alerts_function.tf`.

#### C1. P95 response time — **factual fix**

Replace the existing `function_p95_response_time` (which fires on **average** `HttpResponseTime`) with a KQL alert on App Insights:

```kql
requests
| where timestamp > ago(5m)
| summarize p95 = percentile(duration, 95), total = count()
| where total >= 5
| where p95 > 2000
```

- `duration` is in ms; `> 2000` matches the prior 2s intent.
- `total >= 5` floor for the same reason as the rate alerts: avoid divide-by-tiny noise during quiet windows.
- Sev 2, `azurerm_monitor_scheduled_query_rules_alert_v2`, 5m frequency, 5m window.

#### C2. Function timeout rate

KQL alert on App Insights:

```kql
requests
| where timestamp > ago(5m)
| summarize total = count(),
            timeouts = countif(resultCode in ("408", "504") or toint(duration) >= 230000)
| where total >= 5
| extend pct = 100.0 * timeouts / total
| where pct > 5
```

- `duration >= 230000` ms catches handlers running up to the Consumption-plan 230s limit (the failure mode the original `FunctionTimeouts` metric tracked).
- Sev 2, 5m / 5m.

#### C3. Function failure rate

KQL alert on App Insights:

```kql
requests
| where timestamp > ago(5m)
| summarize total = count(), failed = countif(success == false)
| where total >= 5
| extend pct = 100.0 * failed / total
| where pct > 5
```

- Sev 1, 5m / 5m, `auto_mitigation_enabled = false`.

#### C4. Request rate — anomaly split

Replace the single `request_rate_anomaly` with two metric alerts using `dynamic_criteria`, sensitivity **Medium** (Azure's documented production default):

- `request_rate_drop` — `operator = "LessThan"`, Sev 1, 15m window. Catches partial outages and degraded services.
- `request_rate_spike` — `operator = "GreaterThan"`, Sev 2, 15m window. Surfaces marketing events, scraper traffic, retry storms.

#### C5. Dependency failure rate

KQL alert on App Insights `dependencies`:

```kql
dependencies
| where timestamp > ago(5m)
| summarize total = count(), failed = countif(success == false)
| where total >= 5
| extend pct = 100.0 * failed / total
| where pct > 5
```

- Catches Service Bus send failures, Key Vault read failures, and any other outbound dependency at the App Insights layer.
- Sev 1, 5m / 5m.

**`zero_execution_heartbeat` is removed.** `request_rate_drop` (C4) catches the "no traffic" case via dynamic baseline, without flapping on naturally quiet windows; `count() == 0` is a strict subset of "traffic below baseline."

#### C6. Send-failure spike — structured filter

Replace the existing `send_failure_spike` query:

```kql
exceptions
| where timestamp > ago(5m)
| where type startswith "Azure.Messaging.ServiceBus"
   or outerType startswith "Azure.Messaging.ServiceBus"
| summarize count = count() by bin(timestamp, 5m)
| where count > 2
```

- Filters on exception **type**, not on log-message text. Stable across log-line rewordings.
- App Insights captures `LogError(ex, ...)` calls into the `exceptions` table automatically; no app-code change needed.
- Sev 1, 5m / 5m, `auto_mitigation_enabled = false`.

### D. Service Bus alerts

Move to `terraform/alerts_servicebus.tf`.

#### D1. Aged messages — metric alert on ActiveMessages

Native metric alert on the Service Bus namespace, split by `EntityName` so each queue fires independently:

```hcl
criteria {
  metric_namespace = "Microsoft.ServiceBus/namespaces"
  metric_name      = "ActiveMessages"
  aggregation      = "Average"
  operator         = "GreaterThan"
  threshold        = ${threshold}
  dimension {
    name     = "EntityName"
    operator = "Include"
    values   = ["*"]
  }
}
```

- Sev 2, 15m / 15m.
- A healthy consumer drains the queue fast enough that `ActiveMessages` stays low; sustained elevation means backlog is accumulating.

#### D2. DLQ growth — metric alert

Native metric alert on the Service Bus namespace, split by `EntityName` so each queue fires independently:

```hcl
criteria {
  metric_namespace = "Microsoft.ServiceBus/namespaces"
  metric_name      = "DeadletteredMessages"
  aggregation      = "Maximum"
  operator         = "GreaterThan"
  threshold        = 0
  dimension {
    name     = "EntityName"
    operator = "Include"
    values   = ["*"]
  }
}
```

- Sev 1, 15m / 15m.
- Fires when any queue has dead-lettered messages. The alert stays in "fired" state until the DLQ is drained; it does not fire repeatedly per new arrival.

#### D3. Throttling — new alert

Metric alert on Service Bus namespace:

```hcl
criteria {
  metric_namespace = "Microsoft.ServiceBus/namespaces"
  metric_name      = "ThrottledRequests"
  aggregation      = "Total"
  operator         = "GreaterThan"
  threshold        = 0
}
```

- Sev 2, 5m / 5m.
- Throttling on Standard SKU is the leading indicator of needing to scale up to Premium.

### E. Infrastructure alerts

Move to `terraform/alerts_infra.tf`.

#### E1. Key Vault access-failure alert

Requires `azurerm_monitor_diagnostic_setting` on the Key Vault → `AuditEvent` category → Log Analytics workspace.

KQL alert:

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where TimeGenerated > ago(15m)
| where ResultType != "Success"
| where OperationName in ("SecretGet", "SecretList")
| summarize count()
| where count_ > 0
```

- Sev 1, 15m / 15m, `auto_mitigation_enabled = false`.
- Catches the failure mode where the function or action-group webhook lookup can no longer read secrets (RBAC drift, network policy change, etc.).

### F. Cross-cutting

#### F1. New Terraform variables

```hcl
variable "notification_emails" {
  description = "Email addresses to notify on alerts (used as out-of-band backup to Teams webhook)"
  type        = list(string)
  default     = []
}

variable "owner_team" {
  description = "Team that owns these resources (added to tags and used in alert routing context)"
  type        = string
  default     = "platform"
}

variable "runbook_base_url" {
  description = "Base URL for runbook links embedded in alert descriptions"
  type        = string
  default     = "https://runbooks.example.com/azure-alerting"
}
```

#### F2. Tagging

Every alert resource gets:

```hcl
tags = {
  environment    = var.environment
  project        = var.project_name
  cost-center    = "poc"   # keep until cost center is reassigned
  owner          = var.owner_team
  severity_class = "critical"  # or "warning" or "informational"
  runbook        = "${var.runbook_base_url}/<alert-slug>"
}
```

`cost-center = "poc"` is intentionally left as-is rather than renamed to something prod-flavoured; the cost-center taxonomy is an org concern outside this change.

#### F3. Descriptions

Every alert's `description` ends with `— runbook: ${var.runbook_base_url}/<alert-slug>`. Example:

```hcl
description = "P95 response time exceeds 2 seconds — runbook: ${var.runbook_base_url}/p95-regression"
```

#### F4. Explicit auto-mitigation on KQL alerts

`azurerm_monitor_scheduled_query_rules_alert_v2` resources set `auto_mitigation_enabled` explicitly:

- Sev 1 → `false` (stay open until acknowledged)
- Sev 2 → `true` (auto-resolve when conditions clear)

Metric alerts (`azurerm_monitor_metric_alert`) do not support `auto_mitigation_enabled` — they auto-resolve when their criteria conditions clear naturally.

### G. File layout

`terraform/alerts.tf` shrinks to action groups + watchdog. Domain alerts move out:

```
terraform/
├── alerts.tf                # action groups, watchdog, top-of-file documentation
├── alerts_function.tf       # C1–C6
├── alerts_servicebus.tf     # D1–D3 + diagnostic setting
└── alerts_infra.tf          # E1 + KV diagnostic setting
```

This sets the pattern for future domains (database, networking, etc.) without going back to a single-file structure.

---

## Resource summary

| ID | Resource | Type | Sev | New? |
|---|---|---|---|---|
| A1 | `ag_critical` | action group | — | new (replaces) |
| A2 | `ag_warning` | action group | — | new (replaces) |
| A3 | `ag_watchdog` | action group | — | new |
| B1 | `alerting_watchdog` | scheduled query | 4 | new |
| C1 | `function_p95_response_time` | scheduled query | 2 | rewritten |
| C2 | `function_timeout_rate` | scheduled query | 2 | rewritten |
| C3 | `function_failure_rate` | scheduled query | 1 | rewritten (renamed) |
| C4a | `request_rate_drop` | metric (dynamic) | 1 | new (split) |
| C4b | `request_rate_spike` | metric (dynamic) | 2 | new (split) |
| C5 | `dependency_failure_rate` | scheduled query | 1 | new |
| C6 | `send_failure_spike` | scheduled query | 1 | rewritten |
| D1 | `aged_messages` | metric | 2 | rewritten |
| D2 | `dlq_growth` | metric | 1 | rewritten |
| D3 | `sb_throttling` | metric | 2 | new |
| E1a | `kv_diagnostic_setting` | diagnostic setting | — | new |
| E1b | `kv_access_failure` | scheduled query | 1 | new |

Removed: `request_rate_anomaly` (split into C4a/C4b), `zero_execution_heartbeat` (subsumed by C4a), `function_failure_count` (replaced by C3), `dlq_message_count` (replaced by D2), old single `ag_teams` (replaced by A1+A2).

## Testing

- `terraform validate` and `terraform plan` succeed.
- `scripts/trigger-alerts.ps1` is updated to drive each scenario:
  - Sustained 5xx burst → C3 fires; single 5xx does **not** fire.
  - Sustained timeouts (e.g., handler with `Thread.Sleep`) → C2 fires.
  - Slow handler (~3s) for sustained traffic → C1 fires.
  - 20 rapid requests → C4b (spike) fires; **stopping** traffic after sustained load → C4a (drop) fires.
  - Poison message → D2 fires when any DLQ messages exist.
  - Disable function's Service Bus role → C5 and C6 fire (dependency / exception).
- After deploy, manual confirmation:
  - First hourly watchdog email arrives.
  - Sev 1 alert routes to `ag-critical`; Sev 2 to `ag-warning`. Teams and email both receive.

## Rollout

Single `terraform apply`. Most affected alerts are destroyed and recreated; this stack has no production traffic so notification replay is not a concern. Operators fill in `notification_emails`, `owner_team`, and `runbook_base_url` (or override the defaults) before apply.

## Known limitations / follow-ups

- **In-Azure watchdog only.** If the entire Azure region or the subscription's monitoring plane fails, the watchdog can't tell us. A proper external dead-man's switch (Healthchecks.io, PagerDuty heartbeat, or a separate cloud) is the real fix and is documented as a follow-up.
- **Runbooks are placeholders.** URLs in alert descriptions point at a placeholder base; actual runbook content is a separate workstream.
- **No SLO/error-budget alerts.** Burn-rate alerts on a defined SLO are the next maturity step. The file layout supports adding them without restructuring.
- **No maintenance-window suppression.** Alert processing rules are not configured; deploys will fire spurious alerts until added.

## Open questions

None at design time. Threshold tuning (5%, `total >= 5`, `delta > 0`, anomaly sensitivity Medium) is expected to evolve once real traffic exists.
