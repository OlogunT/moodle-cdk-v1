#!/usr/bin/env pwsh
# Send probe+fix to each candidate individually (skip Windows/unsupported)
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1'
)

$pf = Join-Path $env:TEMP 'probe-fix.json'
Write-Host "Params file: $pf (exists=$(Test-Path $pf))"

$candidates = @(
  'i-0527f81ac3fde0ec3','i-076b687e9bf43a1a4','i-0ac15d6e22f204649',
  'i-0dca2f988e797653f','i-005355f82b1206aff','i-0f3e2ff1be8ff986a',
  'i-0080670f33aeddd08','i-04ee31773fdaa5a5c','i-03c8a62253d2a10a4',
  'i-0bdae18253da2e0c4','i-09c83f782d36e0f40','i-0a7ec1da61c80bdeb'
)

$results = @{}
foreach ($inst in $candidates) {
    $raw = aws --profile $Profile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 60 `
        --query 'Command.CommandId' --output text 2>&1
    $id = ($raw | Out-String).Trim()
    if ($id -match '^[0-9a-f\-]{36}$') {
        Write-Host "SENT  $inst -> $id"
        $results[$inst] = $id
    } else {
        Write-Host "SKIP  $inst : $id"
    }
}

# Save results map
$results | ConvertTo-Json | Set-Content (Join-Path $env:TEMP 'probe-id-map.json')
Write-Host "Saved probe-id-map.json with $($results.Count) sent commands."
Write-Host "Run poll-probe-map.ps1 after 40 seconds."

