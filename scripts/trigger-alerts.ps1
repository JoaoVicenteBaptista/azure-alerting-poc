param(
    [Parameter(Mandatory = $true)]
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
    }
    catch {
        Write-Host "  [$_] ERROR: $_"
    }
}

Write-Host "`n[4/4] Done. Check Azure Monitor alerts and Teams channel."
Write-Host "  Alert evaluation may take 5-15 minutes after triggers."
