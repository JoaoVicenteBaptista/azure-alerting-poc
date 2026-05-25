param(
    [string]$QueueName = "messages"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Azure Alerting — Queue Drain ==="

# Resolve Service Bus info from terraform
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$terraformDir = Resolve-Path "$scriptDir/../terraform"
pushd $terraformDir
$rg             = terraform output -raw resource_group_name
$sbNamespaceFqdn = terraform output -raw service_bus_namespace
popd

# Strip the .servicebus.windows.net suffix to get the short name
$sbNamespace = $sbNamespaceFqdn -replace '\.servicebus\.windows\.net$', ''

Write-Host "Service Bus namespace: $sbNamespace"
Write-Host "Queue: $QueueName"
Write-Host ""

# Service Bus doesn't have a native purge command via Azure CLI.
# We delete and recreate the queue — the fastest way to drain it.
# Note: this also clears the DLQ.
Write-Host "Warning: this will DELETE and recreate queue '$QueueName'."
Write-Host "  - All active messages will be lost"
Write-Host "  - All dead-lettered messages will be lost"
Write-Host "  - The queue is recreated with the same settings as in terraform"
Write-Host ""

$confirm = Read-Host "Continue? [y/N]"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host "Aborted."
    exit 0
}

Write-Host "Deleting queue '$QueueName'..."
az servicebus queue delete `
    --namespace-name $sbNamespace `
    --resource-group $rg `
    --name $QueueName `
    --output none

# Recreate with the same settings defined in terraform/service_bus.tf
Write-Host "Recreating queue '$QueueName'..."
az servicebus queue create `
    --namespace-name $sbNamespace `
    --resource-group $rg `
    --name $QueueName `
    --max-delivery-count 5 `
    --default-message-time-to-live P7D `
    --enable-dead-lettering-on-message-expiration true `
    --output none

Write-Host ""
Write-Host "Queue '$QueueName' drained and recreated."
Write-Host "  Active messages: 0"
Write-Host "  Dead-lettered messages: 0"
