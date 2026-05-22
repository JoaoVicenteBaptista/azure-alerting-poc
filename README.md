# Azure Alerting POC

Terraform-based proof of concept demonstrating Azure infrastructure provisioning with alerting for Function Apps and Service Bus dead-letter queues, with notifications routed to Microsoft Teams.

## Architecture

- **Infrastructure as Code** — Terraform with remote state and Key Vault secret management
- **Application** — .NET 10 isolated Azure Function (HTTP trigger → Service Bus queue)
- **Alerting** — 9 alerts (metric + log query) via Azure Monitor → Action Group → Teams webhook

See [`docs/plans/2026-05-22-azure-alerting-poc-design.md`](docs/plans/2026-05-22-azure-alerting-poc-design.md) for the full design document.

## Quick Start

### Prerequisites

- Azure CLI (`az login`)
- Terraform >= 1.6
- .NET 10 SDK
- Azure Function Core Tools

### Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Teams webhook URL
terraform init
terraform plan
terraform apply
```

### Function App

```bash
cd src/AzureAlertingPoc.Function
func start
```

### Trigger an alert

```bash
# Send a test message
curl -X POST https://<function-app>/api/send \
  -H "Content-Type: application/json" \
  -d '{"test": true}'
```

## Resources Created

- App Service Plan (Consumption)
- Function App (.NET 10 isolated)
- Application Insights (workspace-based)
- Log Analytics Workspace
- Storage Account
- Service Bus Namespace + Queue (DLQ enabled)
- Key Vault (Teams webhook secret)
- Action Group (Teams webhook)
- 9 Metric/Log Alerts (see design doc)

## Project Structure

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
├── src/
│   └── AzureAlertingPoc.Function/
│       ├── Program.cs
│       ├── SendMessageFunction.cs
│       └── AzureAlertingPoc.Function.csproj
└── docs/
    └── plans/
        └── 2026-05-22-azure-alerting-poc-design.md
```
