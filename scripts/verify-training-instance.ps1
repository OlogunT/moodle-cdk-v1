#!/usr/bin/env pwsh
#
# Verify Training Moodle Instance
# Runs verification checks on the EC2 instance
#

param(
  [string]$InstanceId = "i-06e7f96652b2b9620",
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

Write-Host "Verifying Training Moodle instance..." -ForegroundColor Cyan
Write-Host "Instance: $InstanceId" -ForegroundColor Gray
Write-Host ""

# Send SSM command
$cmdId = aws ssm send-command `
  --instance-ids $InstanceId `
  --document-name AWS-RunShellScript `
  --parameters file://scripts/verify-training-instance.json `
  --region $Region `
  --query Command.CommandId `
  --output text

Write-Host "Command sent: $cmdId" -ForegroundColor Green
Write-Host "Waiting for results..." -ForegroundColor Yellow
Write-Host ""

Start-Sleep -Seconds 5

# Wait for command to complete
$maxWait = 30
$waited = 0
while ($waited -lt $maxWait) {
  $status = aws ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id $InstanceId `
    --region $Region `
    --query "Status" `
    --output text 2>$null
  
  if ($status -eq "Success" -or $status -eq "Failed") {
    break
  }
  
  Start-Sleep -Seconds 2
  $waited += 2
}

# Get results
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
aws ssm get-command-invocation `
  --command-id $cmdId `
  --instance-id $InstanceId `
  --region $Region `
  --query "StandardOutputContent" `
  --output text
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

if ($status -eq "Success") {
  Write-Host ""
  Write-Host "✓ Verification completed successfully" -ForegroundColor Green
  exit 0
} else {
  Write-Host ""
  Write-Host "⚠ Verification completed with status: $status" -ForegroundColor Yellow
  
  # Check for errors
  $stderr = aws ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id $InstanceId `
    --region $Region `
    --query "StandardErrorContent" `
    --output text 2>$null
  
  if ($stderr) {
    Write-Host ""
    Write-Host "Errors:" -ForegroundColor Red
    Write-Host $stderr -ForegroundColor Red
  }
  
  exit 1
}

