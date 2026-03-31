#!/usr/bin/env pwsh
# Find the new Moodle web instance (ASG replacement for terminated i-0c386871e2eb20f71)
# and apply the same nuclear fix to it
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1'
)
$ErrorActionPreference = 'Stop'

# All SSM-online instances (excluding known good i-04aa12a6aa64b6e66)
$candidates = @(
  'i-0527f81ac3fde0ec3',
  'i-076b687e9bf43a1a4',
  'i-0ac15d6e22f204649',
  'i-0dca2f988e797653f',
  'i-005355f82b1206aff',
  'i-0f3e2ff1be8ff986a',
  'i-0080670f33aeddd08',
  'i-04ee31773fdaa5a5c',
  'i-03c8a62253d2a10a4',
  'i-0bdae18253da2e0c4',
  'i-09c83f782d36e0f40',
  'i-0a7ec1da61c80bdeb'
)

# Step 1: find which instances have /app/moodle/config.php
Write-Host "=== Step 1: Finding Moodle instances ==="
$pf1 = Join-Path $env:TEMP 'find-moodle.json'
@{ commands = @('test -f /app/moodle/config.php && echo MOODLE_FOUND || echo NOT_MOODLE') } | ConvertTo-Json -Compress | Set-Content -Path $pf1

$findId = (aws --profile $Profile --region $Region ssm send-command `
    --instance-ids @candidates `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf1" `
    --timeout-seconds 30 `
    --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
Write-Host "Find cmd: $findId"

Start-Sleep 20

$moodleInstances = @()
foreach ($inst in $candidates) {
    $r = aws --profile $Profile --region $Region ssm get-command-invocation `
        --command-id $findId --instance-id $inst `
        --query '{S:Status,O:StandardOutputContent}' --output json 2>&1 | ConvertFrom-Json
    $status = "$($r.S) | $($r.O)".Trim()
    Write-Host "  $inst : $status"
    if ($r.O -match 'MOODLE_FOUND') { $moodleInstances += $inst }
}

Write-Host "`n=== Found Moodle instances: $($moodleInstances -join ', ') ==="

if ($moodleInstances.Count -eq 0) {
    Write-Host "No new Moodle instances found. Site may be single-instance now."
    exit 0
}

# Step 2: apply nuclear fix to any Moodle instance that needs it
$pf2 = Join-Path $env:TEMP 'nuclear-restart.json'
foreach ($inst in $moodleInstances) {
    Write-Host "`n=== Applying fix to $inst ==="
    $id = (aws --profile $Profile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf2" `
        --timeout-seconds 120 `
        --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
    Write-Host "  CMD: $id"

    Start-Sleep 50

    $r = aws --profile $Profile --region $Region ssm get-command-invocation `
        --command-id $id --instance-id $inst `
        --query '{S:Status,RC:ResponseCode,O:StandardOutputContent,E:StandardErrorContent}' `
        --output json 2>&1 | ConvertFrom-Json
    Write-Host "  Status: $($r.S) RC: $($r.RC)"
    Write-Host $r.O
    if ($r.E) { Write-Host "STDERR: $($r.E)" }
}
Write-Host "`nAll done."

