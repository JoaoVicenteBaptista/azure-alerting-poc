# Azure Alerting — Original Implementation Plan

**Status:** Historical — executed, then superseded

> **Historical record.** This plan was executed and produced the initial 8-alert layout. That layout has since been reworked to production-grade in [`docs/superpowers/plans/2026-05-24-production-grade-alerts.md`](../superpowers/plans/2026-05-24-production-grade-alerts.md). Original goal text and steps are preserved below verbatim.

**Goal:** Build a Terraform-based stack that provisions Azure infrastructure (Function App + Service Bus + Key Vault + App Insights) with 8 alerts routed to Teams, plus a minimal .NET 10 isolated function that accepts POST requests and drops messages into a Service Bus queue.

**Architecture:** Single Terraform root module split across context files (providers, variables, key_vault, function_app, service_bus, alerts, outputs). Remote state in Azure Storage with locking. Teams webhook secret stored in Key Vault, referenced by Action Group. .NET 10 isolated function uses `IServiceBusSenderFactory` via DI with structured logging and correlation IDs.

> **Note:** This plan was executed and the as-built implementation includes refinements (sender disposal fix, KQL query fix, DLQ alert consolidation, unit tests, CancellationToken support). See the original design at [`2026-05-22-azure-alerting-design.md`](2026-05-22-azure-alerting-design.md).

**Tech Stack:** Terraform 1.6+, AzureRM provider 4.x, .NET 10 isolated worker, Azure Functions, Service Bus, Application Insights, Key Vault, Azure Monitor.

**Design Doc:** `docs/plans/2026-05-22-azure-alerting-poc-design.md`

---

### Task 1: Project scaffolding

**Files:**
- Create: `.gitignore`
- Create: `terraform/` directory (placeholder)
- Create: `src/AzureAlertingPoc.Function/` directory (placeholder)

**Step 1: Create .gitignore**

```bash
cat > .gitignore << 'EOF'
# Terraform
**/.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
.terraform.lock.hcl

# .NET
bin/
obj/
*.user
*.suo
.vs/

# Secrets
*.pfx
*.publishsettings

# OS
.DS_Store
Thumbs.db
EOF
```

**Step 2: Create directories and placeholder .gitkeep files**

```bash
mkdir -p terraform
mkdir -p src/AzureAlertingPoc.Function
touch terraform/.gitkeep src/AzureAlertingPoc.Function/.gitkeep
```

**Step 3: Commit**

```bash
git add .gitignore terraform/.gitkeep src/AzureAlertingPoc.Function/.gitkeep
git commit -m "chore: scaffold project structure and .gitignore"
```

---

### Task 2: Terraform providers.tf

**Files:**
- Create: `terraform/providers.tf`
- Delete: `terraform/.gitkeep`

**Reference:** [AzureRM provider docs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)

**Step 1: Write providers.tf**

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "terraformstate"
    container_name       = "tfstate"
    key                  = "azure-alerting-poc.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}
```

**Step 2: Validate syntax**

Run: `cd terraform && terraform init -backend=false`
Expected: Init succeeds (providers downloaded), no errors.

**Step 3: Commit**

```bash
git add terraform/providers.tf terraform/.gitkeep
git rm terraform/.gitkeep
git commit -m "feat: add terraform provider config"
```

---

### Task 3: Terraform variables.tf

**Files:**
- Create: `terraform/variables.tf`

**Step 1: Write variables.tf**

```hcl
variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "westeurope"
}

variable "project_name" {
  description = "Base name used for resource naming"
  type        = string
  default     = "az-alerting-poc"
}

variable "environment" {
  description = "Environment tag (dev, staging, prod)"
  type        = string
  default     = "poc"
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL for alert notifications"
  type        = string
  sensitive   = true
}

variable "function_app_subnet_prefix" {
  description = "Not used in POC — placeholder for future VNet integration"
  type        = string
  default     = "10.0.1.0/24"
}
```

**Step 2: Run terraform fmt**

Run: `cd terraform && terraform fmt -check -recursive`
Expected: No changes needed (exit code 0) or auto-formats.

**Step 3: Commit**

```bash
git add terraform/variables.tf
git commit -m "feat: add terraform variables"
```

---

### Task 4: Terraform key_vault.tf

**Files:**
- Create: `terraform/key_vault.tf`

**Note on required permissions:** The service principal running `terraform apply` needs `Key Vault Secrets Officer` role on the Key Vault to set the webhook secret. The `object_id` for the service principal should be passed or read from `data.azurerm_client_config`.

**Step 1: Write key_vault.tf**

```hcl
# Random suffix for global uniqueness
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_key_vault" "main" {
  name                       = "kv-${var.project_name}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = 7

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
  ]
}

resource "azurerm_key_vault_secret" "teams_webhook" {
  name         = "teams-webhook-url"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.teams_webhook_url

  depends_on = [azurerm_key_vault_access_policy.terraform]
}
```

**Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: Success (may still reference undeclared resources from other files, that's ok at this stage).

**Step 3: Commit**

```bash
git add terraform/key_vault.tf
git commit -m "feat: add key vault and resource group"
```

---

### Task 5: Terraform function_app.tf

**Files:**
- Create: `terraform/function_app.tf`

**Note:** Function App requires a Storage Account. The Storage Account name must be globally unique — we use the `random_string.suffix` from task 4. Application Insights is workspace-based, requiring a Log Analytics Workspace.

**Step 1: Write function_app.tf**

```hcl
resource "azurerm_storage_account" "function" {
  name                     = "st${replace(var.project_name, "-", "")}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_service_plan" "main" {
  name                = "asp-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Windows"
  sku_name            = "Y1"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_windows_function_app" "main" {
  name                       = "func-${var.project_name}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.function.name
  storage_account_access_key = azurerm_storage_account.function.primary_access_key

  site_config {
    application_stack {
      dotnet_version              = "10"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.main.connection_string
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.main.instrumentation_key
    "AzureWebJobsStorage"                   = azurerm_storage_account.function.primary_connection_string
    "WEBSITE_RUN_FROM_PACKAGE"              = "1"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}
```

**Step 2: Run terraform fmt**

Run: `cd terraform && terraform fmt`
Expected: Files formatted, no errors.

**Step 3: Commit**

```bash
git add terraform/function_app.tf
git commit -m "feat: add function app, app insights, and storage"
```

---

### Task 6: Terraform service_bus.tf

**Files:**
- Create: `terraform/service_bus.tf`

**Note:** Service Bus Namespace requires global uniqueness, using the `random_string.suffix`. Queue `max_delivery_count = 5` ensures messages dead-letter after 5 failed delivery attempts.

**Step 1: Write service_bus.tf**

```hcl
resource "azurerm_servicebus_namespace" "main" {
  name                = "sb-${var.project_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"

  tags = {
    environment = var.environment
    project     = var.project_name
    cost-center = "poc"
  }
}

resource "azurerm_servicebus_queue" "main" {
  name                = "messages"
  namespace_id        = azurerm_servicebus_namespace.main.id
  max_delivery_count  = 5
  default_message_ttl = "P7D"

  # Dead-lettering settings
  dead_lettering_on_message_expiration = true
}
```

**Step 2: Add Service Bus connection string to function app settings**

After the Service Bus resources exist, add the connection string to the function app's `app_settings` in `function_app.tf`. Open `terraform/function_app.tf` and add this entry inside the `app_settings` block, after the `"WEBSITE_RUN_FROM_PACKAGE"` line:

```hcl
    "ServiceBusConnection__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
```

**Step 3: Commit**

```bash
git add terraform/service_bus.tf terraform/function_app.tf
git commit -m "feat: add service bus namespace and queue"
```

---

### Task 7: Terraform alerts.tf

**Files:**
- Create: `terraform/alerts.tf`

**Reference:** [azurerm_monitor_action_group](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group), [azurerm_monitor_metric_alert](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert), [azurerm_monitor_scheduled_query_rules_alert_v2](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_scheduled_query_rules_alert_v2)

**Step 1: Write alerts.tf — Action Group**

```hcl
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
  name                = "alert-func-send-failure-spike"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.main.id]
  description         = "Send failure spike detected — >2 failures in 5 minutes"
  severity            = 1
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

    resource_id_column      = "appName"
    metric_measure_column   = "count_"
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
  name                = "alert-func-zero-execution"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.main.id]
  description         = "No requests received in 10 minutes — possible dead function"
  severity            = 1
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
```

**Step 2: Run terraform fmt and validate**

Run: `cd terraform && terraform fmt && terraform validate`
Expected: Files formatted, validate succeeds (resource references may show as unknown if not all present yet — that's expected).

**Step 3: Commit**

```bash
git add terraform/alerts.tf
git commit -m "feat: add action group and 9 monitoring alerts"
```

---

### Task 8: Terraform outputs.tf

**Files:**
- Create: `terraform/outputs.tf`

**Step 1: Write outputs.tf**

```hcl
output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "function_app_name" {
  description = "Function App name"
  value       = azurerm_windows_function_app.main.name
}

output "function_app_url" {
  description = "Function App base URL"
  value       = "https://${azurerm_windows_function_app.main.default_hostname}"
}

output "application_insights_connection_string" {
  description = "App Insights connection string"
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "service_bus_namespace" {
  description = "Service Bus namespace FQDN"
  value       = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

output "service_bus_queue_name" {
  description = "Service Bus queue name"
  value       = azurerm_servicebus_queue.main.name
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.main.vault_uri
}
```

**Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: Success.

**Step 3: Commit**

```bash
git add terraform/outputs.tf
git commit -m "feat: add terraform outputs"
```

---

### Task 9: Terraform tfvars example

**Files:**
- Create: `terraform/terraform.tfvars.example`

**Step 1: Write terraform.tfvars.example**

```hcl
location         = "westeurope"
project_name     = "az-alerting-poc"
environment      = "poc"
teams_webhook_url = "https://your-org.webhook.office.com/webhookb2/..."
```

**Step 2: Commit**

```bash
git add terraform/terraform.tfvars.example
git commit -m "feat: add terraform.tfvars.example"
```

---

### Task 10: Full Terraform validation

**Files:**
- No new files — validation pass over all existing Terraform

**Step 1: Verify .gitignore excludes tfvars**

Run: `git status`
Expected: `terraform.tfvars` should NOT appear (gitignored), only `terraform.tfvars.example`.

**Step 2: Run terraform init (with backend override for local validation)**

Run: `cd terraform && terraform init -backend=false`
Expected: Providers download, init succeeds.

**Step 3: Run terraform fmt -check**

Run: `cd terraform && terraform fmt -check -recursive`
Expected: No formatting issues (exit code 0). If issues found, run `terraform fmt -recursive` and re-check.

**Step 4: Run terraform validate**

Run: `cd terraform && terraform validate`
Expected: "Success! The configuration is valid."

**Step 5: Commit any formatting fixes**

```bash
git add -A
git commit -m "chore: terraform validation pass"
```

---

### Task 11: .NET Function project scaffolding

**Files:**
- Create: `src/AzureAlertingPoc.Function/AzureAlertingPoc.Function.csproj`
- Create: `src/AzureAlertingPoc.Function/host.json`
- Create: `src/AzureAlertingPoc.Function/local.settings.json`
- Delete: `src/AzureAlertingPoc.Function/.gitkeep`

**Step 1: Write .csproj**

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <AzureFunctionsVersion>v4</AzureFunctionsVersion>
    <OutputType>Exe</OutputType>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <RootNamespace>AzureAlertingPoc.Function</RootNamespace>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Azure.Functions.Worker" Version="2.0.0" />
    <PackageReference Include="Microsoft.Azure.Functions.Worker.Extensions.Http" Version="4.0.0" />
    <PackageReference Include="Microsoft.Azure.Functions.Worker.Sdk" Version="2.0.0" />
    <PackageReference Include="Azure.Messaging.ServiceBus" Version="7.18.0" />
  </ItemGroup>

  <ItemGroup>
    <None Update="host.json">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </None>
    <None Update="local.settings.json">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <CopyToPublishDirectory>Never</CopyToPublishDirectory>
    </None>
  </ItemGroup>
</Project>
```

**Step 2: Write host.json**

```json
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true,
        "excludedTypes": "Request"
      }
    },
    "logLevel": {
      "default": "Information",
      "Host.Results": "Information",
      "Function": "Information"
    }
  }
}
```

**Step 3: Write local.settings.json**

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "ServiceBusConnection__fullyQualifiedNamespace": "sb-az-alerting-poc.servicebus.windows.net"
  }
}
```

**Step 4: Restore NuGet packages and build**

Run: `cd src/AzureAlertingPoc.Function && dotnet restore && dotnet build`
Expected: Build succeeds, no errors.

**Step 5: Commit**

```bash
git add src/AzureAlertingPoc.Function/ && git rm --cached src/AzureAlertingPoc.Function/.gitkeep 2>/dev/null; git add -u
git commit -m "feat: scaffold .NET 10 isolated function project"
```

---

### Task 12: SendMessageFunction.cs

**Files:**
- Create: `src/AzureAlertingPoc.Function/SendMessageFunction.cs`

**Step 1: Write the function**

```csharp
using System.Text;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace AzureAlertingPoc.Function;

public class SendMessageFunction
{
    private readonly ServiceBusClient _serviceBusClient;
    private readonly ILogger<SendMessageFunction> _logger;

    // TODO: Replace with queue name from configuration in production
    private const string QueueName = "messages";

    public SendMessageFunction(
        ServiceBusClient serviceBusClient,
        ILogger<SendMessageFunction> logger)
    {
        _serviceBusClient = serviceBusClient;
        _logger = logger;
    }

    [Function("SendMessage")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "send")]
        HttpRequestData request)
    {
        var correlationId = Guid.NewGuid().ToString("D");

        string requestBody;
        using (var reader = new StreamReader(request.Body, Encoding.UTF8))
        {
            requestBody = await reader.ReadToEndAsync();
        }

        _logger.LogInformation(
            "Received send request. CorrelationId: {CorrelationId}, BodySize: {BodySize}",
            correlationId,
            requestBody.Length);

        try
        {
            var sender = _serviceBusClient.CreateSender(QueueName);

            var message = new ServiceBusMessage(requestBody)
            {
                MessageId = correlationId,
                ContentType = "application/json"
            };
            message.ApplicationProperties.Add("Source", "az-alerting-poc");
            message.ApplicationProperties.Add("CorrelationId", correlationId);

            await sender.SendMessageAsync(message);

            _logger.LogInformation(
                "Message sent to queue. CorrelationId: {CorrelationId}, MessageId: {MessageId}",
                correlationId,
                message.MessageId);

            var response = request.CreateResponse(System.Net.HttpStatusCode.Accepted);
            response.Headers.Add("X-Correlation-Id", correlationId);
            await response.WriteStringAsync(
                JsonSerializer.Serialize(new { correlationId, status = "accepted" }));

            return response;
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Failed to send message to queue. CorrelationId: {CorrelationId}",
                correlationId);

            var errorResponse = request.CreateResponse(
                System.Net.HttpStatusCode.InternalServerError);
            await errorResponse.WriteStringAsync(
                JsonSerializer.Serialize(new
                {
                    correlationId,
                    status = "error",
                    error = "Failed to send message to Service Bus queue"
                }));

            return errorResponse;
        }
    }
}
```

**Step 2: Build to verify compilation**

Run: `cd src/AzureAlertingPoc.Function && dotnet build`
Expected: Build succeeds, no errors.

**Step 3: Commit**

```bash
git add src/AzureAlertingPoc.Function/SendMessageFunction.cs
git commit -m "feat: add SendMessage function with correlation ID logging"
```

---

### Task 13: Program.cs (DI registration)

**Files:**
- Create: `src/AzureAlertingPoc.Function/Program.cs`

**Step 1: Write Program.cs**

```csharp
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace AzureAlertingPoc.Function;

public class Program
{
    public static void Main(string[] args)
    {
        var host = new HostBuilder()
            .ConfigureFunctionsWebApplication()
            .ConfigureServices(services =>
            {
                services.AddSingleton(provider =>
                {
                    var fullyQualifiedNamespace = Environment
                        .GetEnvironmentVariable(
                            "ServiceBusConnection__fullyQualifiedNamespace")
                        ?? throw new InvalidOperationException(
                            "ServiceBusConnection__fullyQualifiedNamespace " +
                            "environment variable is not set.");

                    var credential = new Azure.Identity.DefaultAzureCredential();

                    return new ServiceBusClient(
                        fullyQualifiedNamespace,
                        credential);
                });
            })
            .Build();

        host.Run();
    }
}
```

**Note:** The function uses `DefaultAzureCredential` for Service Bus auth. This requires the Function App's managed identity to have the `Azure Service Bus Data Sender` role on the Service Bus namespace. We'll add this RBAC assignment in a follow-up step or note it as a manual post-deploy step.

**Step 2: Build**

Run: `cd src/AzureAlertingPoc.Function && dotnet build`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add src/AzureAlertingPoc.Function/Program.cs
git commit -m "feat: add Program.cs with DI and ServiceBusClient"
```

---

### Task 14: Add RBAC role assignment for Managed Identity → Service Bus

**Files:**
- Modify: `terraform/service_bus.tf` (append RBAC role assignment)

**Note:** The function uses `DefaultAzureCredential` which will use the Function App's system-assigned managed identity. We need to grant that identity `Azure Service Bus Data Sender` on the Service Bus namespace.

**Step 1: Append RBAC assignment to service_bus.tf**

Add the following at the end of `terraform/service_bus.tf`:

```hcl
# Grant Function App's managed identity Azure Service Bus Data Sender role
resource "azurerm_role_assignment" "function_sb_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_windows_function_app.main.identity[0].principal_id
}
```

**Step 2: Run terraform fmt and validate**

Run: `cd terraform && terraform fmt && terraform validate`
Expected: Files formatted, validate succeeds.

**Step 3: Commit**

```bash
git add terraform/service_bus.tf
git commit -m "feat: add RBAC role assignment for Function App -> Service Bus"
```

---

### Task 15: Final validation and README review

**Files:**
- Verify: All files are committed
- Review: `README.md` against implemented reality

**Step 1: Final terraform validation**

Run:
```bash
cd terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
```
Expected: All pass, no errors.

**Step 2: Final .NET build**

Run: `cd src/AzureAlertingPoc.Function && dotnet build --configuration Release`
Expected: Build succeeds.

**Step 3: List all tracked files**

Run: `git ls-files`
Expected: All expected files listed, no missing, no extras.

**Step 4: Commit any final changes**

```bash
git add -A
git commit -m "chore: final validation pass"
```

---

### Task 16: Create a test script for manual alert triggering

**Files:**
- Create: `scripts/trigger-alerts.ps1`

**Step 1: Write trigger-alerts.ps1**

```powershell
param(
    [Parameter(Mandatory=$true)]
    [string]$FunctionAppUrl,

    [string]$ApiKey
)

$headers = @{
    "Content-Type" = "application/json"
}

if ($ApiKey) {
    $headers["x-functions-key"] = $ApiKey
}

Write-Host "=== Azure Alerting POC — Alert Trigger Script ==="

# 1. Normal request — should succeed, no alerts
Write-Host "`n[1/4] Sending normal request..."
$response = Invoke-RestMethod -Uri "$FunctionAppUrl/api/send" -Method Post -Headers $headers -Body '{"test":"normal"}'
Write-Host "  CorrelationId: $($response.correlationId)"
Write-Host "  Status: $($response.status)"

# 2. Large payload — check response time
Write-Host "`n[2/4] Sending large payload (>100KB)..."
$largePayload = '{"data":"' + ('x' * 102400) + '"}'
$response = Invoke-RestMethod -Uri "$FunctionAppUrl/api/send" -Method Post -Headers $headers -Body $largePayload
Write-Host "  CorrelationId: $($response.correlationId)"
Write-Host "  Status: $($response.status)"

# 3. Multiple rapid requests — test rate anomaly
Write-Host "`n[3/4] Sending 20 rapid requests..."
1..20 | ForEach-Object {
    $body = "{`"request`": $_}"
    try {
        $response = Invoke-RestMethod -Uri "$FunctionAppUrl/api/send" -Method Post -Headers $headers -Body $body
        Write-Host "  [$_] CorrelationId: $($response.correlationId) — $($response.status)"
    } catch {
        Write-Host "  [$_] ERROR: $_"
    }
}

Write-Host "`n[4/4] Done. Check Azure Monitor alerts and Teams channel."
Write-Host "  Alert evaluation may take 5-15 minutes after triggers."
```

**Step 2: Commit**

```bash
git add scripts/trigger-alerts.ps1
git commit -m "feat: add manual alert trigger script"
```

---

## Post-Deploy Manual Steps

After `terraform apply` completes:

1. **Deploy the function code** to the provisioned Function App (via `func azure functionapp publish` or CI/CD)
2. **Verify RBAC**: Ensure the Function App's managed identity has `Azure Service Bus Data Sender` on the Service Bus namespace (this is in the Terraform but verify it applied)
3. **Test alerts**: Run `scripts/trigger-alerts.ps1` and wait 5-15 minutes for alert evaluation windows
4. **Check Teams**: Confirm alerts appear in the configured Teams channel
