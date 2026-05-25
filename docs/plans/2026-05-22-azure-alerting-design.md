# Azure Alerting — Original Design Document

**Date:** 2026-05-22
**Status:** Historical — superseded

> **Historical record.** This document captures the original design from the early phase of the project. The alerting layer has since been reworked to production-grade — see [`docs/superpowers/specs/2026-05-24-rate-based-alerts-design.md`](../superpowers/specs/2026-05-24-rate-based-alerts-design.md) for the current design. Text below is preserved verbatim as a point-in-time record.

## Overview

A Terraform-based POC that provisions Azure infrastructure for alerting on an Azure Function App and a Service Bus dead-letter queue. Includes a minimal .NET 10 HTTP-triggered function that drops messages into a queue as a tracing vehicle. All alerts route to Microsoft Teams via an Action Group webhook.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Terraform IaC                         │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Key Vault    │  │ Function App │  │ Service Bus   │  │
│  │ (webhook)    │  │ + AppInsights│  │ Namespace +   │  │
│  │              │  │ + ASP        │  │ Queue (+DLQ)  │  │
│  └──────┬───────┘  └──────┬───────┘  └───────┬───────┘  │
│         │                 │                   │          │
│         │    ┌────────────┴───────────┐       │          │
│         │    │    Metric Alerts       │       │          │
│         │    │  + Log Query Alerts    │       │          │
│         │    └────────────┬───────────┘       │          │
│         │                 │                   │          │
│         └─────────────────┼───────────────────┘          │
│                           │                              │
│                    ┌──────┴──────┐                       │
│                    │Action Group │                       │
│                    │  (Webhook)  │                       │
│                    └──────┬──────┘                       │
└───────────────────────────┼──────────────────────────────┘
                            │
                    ┌───────┴───────┐
                    │ Microsoft     │
                    │ Teams Channel │
                    └───────────────┘
```

## Terraform Structure

Single root module, organized by context:

- **`providers.tf`** — Provider config, remote state backend
- **`variables.tf`** — All inputs (sensitive webhook URL)
- **`key_vault.tf`** — Key Vault + secret for Teams webhook URL
- **`function_app.tf`** — App Service Plan, Function App, Application Insights
- **`service_bus.tf`** — Service Bus Namespace, Queue
- **`alerts.tf`** — Action Group, all metric alerts, log query alerts
- **`outputs.tf`** — Output values

### Resource Naming & Tagging

- `random_string` suffix on globally unique resources (Storage, Service Bus namespace)
- Consistent tags: `environment`, `project = "azure-alerting-poc"`, `cost-center`

### State Management

Remote state in Azure Storage with locking. `terraform.tfvars` is gitignored.

### Key Vault

The Teams webhook URL is stored as an Azure Key Vault secret. The Action Group references it at deploy time via `azurerm_key_vault_secret`.

## Azure Resources

| Resource | SKU / Tier | Notes |
|---|---|---|
| App Service Plan | Y1:0 (Consumption) | Free tier, sufficient for POC |
| Function App | Consumption | .NET 10, runtime stack dotnet-isolated |
| Application Insights | Workspace-based | Connected to Log Analytics Workspace |
| Log Analytics Workspace | PerGB2018 | Required for workspace-based App Insights |
| Storage Account | Standard LRS | Required by Function App |
| Service Bus Namespace | Standard | Full metric set + topics support |
| Service Bus Queue | — | `max_delivery_count = 5` |
| Key Vault | Standard | Holds Teams webhook secret |
| Action Group | — | Webhook receiver → Teams |
| Metric Alerts (6) | — | See alert specification below |
| Log Query Alerts (2) | — | See alert specification below |

## Webhook Secret Management

Two approaches are considered for managing the Teams webhook URL:

### Approach A: Single-Stage (POC Default)

```
terraform.tfvars (gitignored, operator machine only)
    ↓
var.teams_webhook_url (sensitive = true)
    ↓
azurerm_key_vault_secret (encrypted at rest in Azure KV)
    ↓
data.azurerm_key_vault_secret (read by Action Group at deploy time)
```

- **Upside:** Single `terraform apply` provisions everything including the secret
- **Downside:** Webhook URL passes through Terraform state (encrypted in Azure Storage, but present)
- **Suitable for:** POCs and single-environment setups

### Approach B: Two-Stage with Pre-Provisioned KV (Production Recommended)

The Key Vault and secret exist before the main stack. No webhook URL ever enters Terraform state.

**Stage 1 — Platform bootstrap (run once):**

```bash
# Manual or via a minimal bootstrap Terraform stack
az keyvault create --name kv-platform-shared --resource-group rg-platform
az keyvault secret set --vault-name kv-platform-shared \
  --name teams-webhook-url \
  --value "https://..."

# Grant the deployment service principal read access
az keyvault set-policy --name kv-platform-shared \
  --spn <deployment-spn-object-id> \
  --secret-permissions get list
```

**Stage 2 — Main stack (idempotent, repeatable):**

The main stack no longer creates a Key Vault or secret. It only reads from the pre-existing vault:

```hcl
# No var.teams_webhook_url variable
# No azurerm_key_vault_secret resource
# No azurerm_key_vault resource

data "azurerm_key_vault" "platform" {
  name                = "kv-platform-shared"
  resource_group_name = "rg-platform"
}

data "azurerm_key_vault_secret" "teams_webhook" {
  name         = "teams-webhook-url"
  key_vault_id = data.azurerm_key_vault.platform.id
}

# Same Action Group and alerts as before
resource "azurerm_monitor_action_group" "teams" {
  # ...
  webhook_receiver {
    service_uri = data.azurerm_key_vault_secret.teams_webhook.value
  }
}
```

- **Upside:** Webhook URL never in Terraform state; KV and secret lifecycle decoupled from application stack; secret can be rotated independently
- **Downside:** Requires pre-existing platform Key Vault; two-stage provisioning; deployment SPN needs KV read access
- **Suitable for:** Production, multi-environment, and when secrets should never touch IaC state

### Recommendation

For this POC, **Approach A** is implemented. For production use, migrate to **Approach B** by extracting the Key Vault into a separate platform/bootstrap stack and switching the main stack to read-only `data` references.

---

## Alert Specification

All alerts route through a single Action Group → Teams webhook.

### Sev 2 — Warning (investigate within business hours)

| # | Alert Name | Scope | Signal | Threshold | Window |
|---|---|---|---|---|---|
| 1 | Function P95 Response Time | App Insights | `requests/duration` P95 | > 2s | 5 min |
| 2 | Function Timeout Rate | App Insights | `requests/count` resultCode=timeout | > 0 | 5 min |
| 3 | Aged Messages in Queue | Service Bus | Average message age | > 300s | 5 min |
| 4 | Request Rate Anomaly | App Insights | Dynamic threshold on `requests/count` | High sensitivity | 15 min |

### Sev 1 — Critical (immediate attention)

| # | Alert Name | Scope | Signal | Threshold | Window |
|---|---|---|---|---|---|
| 5 | Function Failure Count | App Service | `RequestsFailed` | > 0 | 5 min |
| 6 | DLQ Message Count | Service Bus | `DeadletteredMessages` | > 0 | 5 min |

### Log Query Alerts (Sev 1)

| # | Alert Name | Query | Threshold |
|---|---|---|---|
| 7 | Send Failure Spike | `traces \| where severityLevel >= 3 \| where message contains "Failed to send" \| summarize count() by bin(5m)` | > 2 in 5 min |
| 8 | Zero Execution Heartbeat | `requests \| summarize count()` | == 0 |

## .NET 10 Function App

Single HTTP-triggered function (`POST /api/send`).

### Behavior

1. Accepts JSON body (pass-through, any shape)
2. Generates correlation ID (`Guid.NewGuid()`)
3. Logs request received: `LogInformation("Received send request. CorrelationId: {id}, BodySize: {bytes}")`
4. Sends message via injected `IServiceBusSenderFactory` with:
   - `MessageId` = correlation ID
   - Custom property: `Source = "az-alerting-poc"`
   - Body = serialized request JSON
5. Logs success: `LogInformation("Message sent to queue. CorrelationId: {id}, MessageId: {msgId}")`
6. Logs failure: `LogError(ex, "Failed to send message to queue. CorrelationId: {id}")`
7. Returns 202 Accepted with correlation ID header

### Project Structure

```
src/
  AzureAlertingPoc.Function/
    Program.cs                    — Host builder, DI registration
    SendMessageFunction.cs        — HttpTrigger function
    IServiceBusSenderFactory.cs   — Abstraction for testability
    ServiceBusSenderFactory.cs    — Default Service Bus sender factory
    host.json                     — Functions host config
    local.settings.json           — Local development settings
    AzureAlertingPoc.Function.csproj

tests/
  AzureAlertingPoc.Function.Tests/
    SendMessageFunctionTests.cs   — Unit tests (xUnit + Moq)
    AzureAlertingPoc.Function.Tests.csproj
```

### Dependencies

- `Microsoft.Azure.Functions.Worker`
- `Microsoft.Azure.Functions.Worker.Extensions.Http`
- `Microsoft.Azure.Functions.Worker.Extensions.Http.AspNetCore`
- `Azure.Messaging.ServiceBus`
- `Azure.Identity`

### Logging Strategy

The three log patterns (request received, send success, send failure) feed the log-based alerts defined above. The correlation ID ties the entire trace together across HTTP → queue → potential DLQ.

## How to Trigger Alerts for Testing

- **Function failures:** Send a malformed request that causes an unhandled exception
- **DLQ message:** Send messages that a queue consumer would intentionally reject (abandon > 5 times), or configure a short `max_delivery_count` on a test queue
- **Response time:** Artificially delay the function with `Task.Delay(3000)`
- **Timeouts:** Send a request to a function version with an infinite loop (consumption plan 5-min timeout)
- **Aged messages:** Send messages without a consumer running
- **Send failure spike:** Cause the Service Bus client to fail (e.g., invalid connection string temporarily)

## What This POC Does NOT Cover

- Networking (VNet, private endpoints)
- CI/CD pipeline for Terraform
- Multi-environment (dev/staging/prod)
- Azure Policy enforcement
- Dashboard / workbook creation
