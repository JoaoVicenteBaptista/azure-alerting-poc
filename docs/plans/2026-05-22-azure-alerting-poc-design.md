# Azure Alerting POC — Design Document

**Date:** 2026-05-22  
**Status:** Validated

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
| Metric Alerts (7) | — | See alert specification below |
| Log Query Alerts (2) | — | See alert specification below |

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
| 7 | DLQ Poison Depth | Service Bus | `DeadletteredMessages` | > 3 | 5 min |

### Log Query Alerts (Sev 1)

| # | Alert Name | Query | Threshold |
|---|---|---|---|
| 8 | Send Failure Spike | `traces \| where severityLevel >= 3 \| where message contains "Failed to send" \| summarize count() by bin(5m)` | > 2 in 5 min |
| 9 | Zero Execution Heartbeat | `requests \| where timestamp > ago(10m) \| summarize count()` | == 0 |

## .NET 10 Function App

Single HTTP-triggered function (`POST /api/send`).

### Behavior

1. Accepts JSON body (pass-through, any shape)
2. Generates correlation ID (`Guid.NewGuid()`)
3. Logs request received: `LogInformation("Received send request. CorrelationId: {id}, BodySize: {bytes}")`
4. Sends message via injected `ServiceBusClient` with:
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
    Program.cs           — Host builder, DI registration
    SendMessageFunction.cs — HttpTrigger function
    AzureAlertingPoc.Function.csproj
```

### Dependencies

- `Microsoft.Azure.Functions.Worker`
- `Microsoft.Azure.Functions.Worker.Extensions.Http`
- `Azure.Messaging.ServiceBus`

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
- RBAC / Managed Identity for function → Service Bus auth (connection string used for simplicity)
- CI/CD pipeline for Terraform
- Multi-environment (dev/staging/prod)
- Azure Policy enforcement
- Dashboard / workbook creation
