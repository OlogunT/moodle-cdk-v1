#!/usr/bin/env pwsh
# Check Redis/session cache configuration and connectivity on a Training instance via SSM
param(
  [Parameter(Mandatory=$true)][string]$InstanceId,
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

function Invoke-SSMScript([string]$DocPath, [string]$Label){
  if (-not (Test-Path $DocPath)) { Write-Host "[$Label] Missing: $DocPath" -ForegroundColor Yellow; return 1 }
  $cmdId = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name AWS-RunShellScript `
    --parameters file://$DocPath `
    --region $Region `
    --query Command.CommandId `
    --output text
  Write-Host "[$Label] Command: $cmdId" -ForegroundColor Gray
  $deadline = (Get-Date).AddMinutes(2)
  do {
    Start-Sleep -Seconds 2
    $status = aws ssm get-command-invocation `
      --command-id $cmdId `
      --instance-id $InstanceId `
      --region $Region `
      --query Status `
      --output text 2>$null
  } while ($status -notin @('Success','Failed','TimedOut','Cancelled') -and (Get-Date) -lt $deadline)

  Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
  Write-Host "[$Label] Status: $status" -ForegroundColor Cyan
  aws ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id $InstanceId `
    --region $Region `
    --query StandardOutputContent `
    --output text
  $stderr = aws ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id $InstanceId `
    --region $Region `
    --query StandardErrorContent `
    --output text 2>$null
  if ($stderr) { Write-Host "--- STDERR ---" -ForegroundColor Yellow; Write-Host $stderr }
  Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
  if ($status -eq 'Success') { return 0 } else { return 1 }
}

Write-Host "Checking Redis on Training instance $InstanceId ($Region)" -ForegroundColor Cyan
# 1) Check for config.php Redis settings (non-invasive)
$rc1 = Invoke-SSMScript -DocPath 'scripts/ssm-verify-redis-config.json' -Label 'TRAINING REDIS (config)'
# 2) Connectivity to endpoint from SSM parameter (if shared with Learning)
$rc2 = Invoke-SSMScript -DocPath 'scripts/ssm-verify-redis-learning.json' -Label 'TRAINING REDIS (connectivity)'

if ($rc1 -eq 0 -and $rc2 -eq 0) {
  Write-Host "✓ Redis configuration and connectivity checks passed" -ForegroundColor Green
  exit 0
} elseif ($rc1 -eq 0 -or $rc2 -eq 0) {
  Write-Host "⚠ Partial success: one of the checks failed" -ForegroundColor Yellow
  exit 2
} else {
  Write-Host "✗ Redis checks failed" -ForegroundColor Red
  exit 1
}

