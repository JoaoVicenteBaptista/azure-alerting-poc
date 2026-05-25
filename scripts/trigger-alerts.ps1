param(
    [ValidateSet('spike','failure','delay','timeout','backlog','all')]
    [string]$Alert = 'all',
    [string]$FunctionAppUrl,
    [string]$ApiKey
)

$ErrorActionPreference = "Stop"

# Resolve function app URL from terraform if not provided
if (-not $FunctionAppUrl) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $terraformDir = Resolve-Path "$scriptDir/../terraform"
    pushd $terraformDir
    $rg   = terraform output -raw resource_group_name
    $name = terraform output -raw function_app_name
    $FunctionAppUrl = terraform output -raw function_app_url
    popd
}
else {
    # Derive $rg and $name from the URL for key lookup
    $name = ($FunctionAppUrl -replace '^https://([^.]+).*', '$1')
}

# Resolve function key if not provided
if (-not $ApiKey) {
    if (-not $rg -or -not $name) {
        # Try terraform again if we don't have $rg/$name
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $terraformDir = Resolve-Path "$scriptDir/../terraform"
        pushd $terraformDir
        $rg   = terraform output -raw resource_group_name
        $name = terraform output -raw function_app_name
        popd
    }
    Write-Host "Fetching function key..."
    $ApiKey = az functionapp keys list --resource-group $rg --name $name --query "masterKey" -o tsv
    if (-not $ApiKey) {
        throw "Failed to retrieve function key. Ensure az CLI is authenticated and the function app exists."
    }
}

# Append ?code= to the URL (strip any existing query string first)
$baseUrl = $FunctionAppUrl -replace '\?.*$', ''
$uri = "$baseUrl/api/send?code=$ApiKey"

$headers = @{
    "Content-Type" = "application/json"
}

Write-Host "=== Azure Alerting — Alert Trigger Script ==="
Write-Host "Target: $baseUrl"
Write-Host "Alert mode: $Alert"

# Build the ordered list of steps to run
$steps = if ($Alert -eq 'all') {
    @('spike','failure','delay','timeout','backlog')
} else {
    @($Alert)
}

$stepNum = 0
$total = $steps.Count

foreach ($step in $steps) {
    $stepNum++
    $label = "[$stepNum/$total]"

    switch ($step) {

        'spike' {
            # Rapid requests — triggers execution_spike
            Write-Host "`n$label Sending 20 rapid requests (execution_spike)..."
            1..20 | ForEach-Object {
                $body = "{`"request`": $_}"
                try {
                    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
                    Write-Host "  [$_] CorrelationId: $($response.correlationId) — $($response.status)"
                }
                catch {
                    Write-Host "  [$_] ERROR: $_"
                }
            }
        }

        'failure' {
            # Simulated 500s — triggers function_failure_rate,
            # dependency_failure_rate, send_failure_spike
            Write-Host "`n$label Sending 8 simulated failures (function_failure_rate, dependency_failure_rate, send_failure_spike)..."
            $failureUri = "$baseUrl/api/send?code=$ApiKey&simulateFailure=true"
            1..8 | ForEach-Object {
                $body = "{`"request`": $_}"
                try {
                    $response = Invoke-RestMethod -Uri $failureUri -Method Post -Headers $headers -Body $body
                    Write-Host "  [$_] CorrelationId: $($response.correlationId) — $($response.status)"
                }
                catch {
                    Write-Host "  [$_] ERROR (expected): $($_.Exception.Response.StatusCode.value__)"
                }
            }
        }

        'delay' {
            # Slow responses — triggers function_p95_response_time
            Write-Host "`n$label Sending 8 slow requests — 3s delay each (function_p95_response_time)..."
            $delayUri = "$baseUrl/api/send?code=$ApiKey&simulateDelay=3000"
            1..8 | ForEach-Object {
                $body = "{`"request`": $_}"
                try {
                    $response = Invoke-RestMethod -Uri $delayUri -Method Post -Headers $headers -Body $body
                    Write-Host "  [$_] CorrelationId: $($response.correlationId) — $($response.status)"
                }
                catch {
                    Write-Host "  [$_] ERROR: $_"
                }
            }
        }

        'timeout' {
            # Simulated timeout — triggers function_timeout_rate
            Write-Host "`n$label Timeout test — each request takes ~230s (function_timeout_rate)."
            $runTimeout = Read-Host "  Run timeout step? [y/N]"
            if ($runTimeout -eq 'y' -or $runTimeout -eq 'Y') {
                $timeoutUri = "$baseUrl/api/send?code=$ApiKey&simulateTimeout=230"
                1..2 | ForEach-Object {
                    $body = "{`"request`": $_}"
                    Write-Host "  [$_] Sending timeout request (waiting up to 240s)..."
                    try {
                        $response = Invoke-RestMethod -Uri $timeoutUri -Method Post -Headers $headers -Body $body -TimeoutSec 300
                        Write-Host "  [$_] CorrelationId: $($response.correlationId) — $($response.status)"
                    }
                    catch {
                        Write-Host "  [$_] ERROR (expected): timeout or 504"
                    }
                }
            }
            else {
                Write-Host "  Skipped."
            }
        }

        'backlog' {
            # Queue backlog — triggers aged_messages
            Write-Host "`n$label Sending 700 messages to build queue backlog (aged_messages)..."
            1..700 | ForEach-Object {
                $body = "{`"batch`": $_}"
                try {
                    $null = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
                }
                catch {
                    # Continue on errors — we just want volume
                }
                if ($_ % 100 -eq 0) {
                    Write-Host "  Sent $_ messages..."
                }
            }
            Write-Host "  Done. Use ./scripts/drain-messages.ps1 to clear the backlog."
        }
    }
}

Write-Host "`nDone. Check Azure Monitor alerts and Teams channel."
Write-Host "  Alert evaluation may take 5-15 minutes after triggers."
Write-Host ""
Write-Host "To test execution_heartbeat alert: stop all traffic to the"
Write-Host "function for at least 15 minutes. The alert fires when zero"
Write-Host "executions are detected in a 15-minute window."
