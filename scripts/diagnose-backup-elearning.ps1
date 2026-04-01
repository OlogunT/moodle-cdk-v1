#!/usr/bin/env pwsh
# Diagnose backup and copy issues on elearning.tsin.ca

$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Diagnosing Backup/Copy Issues - ELEARNING" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Get the instance ID for elearning (MoodleCdkStack)
Write-Host "Finding elearning instance..." -ForegroundColor Yellow
$instanceId = aws ec2 describe-instances `
    --profile account-483382415631 `
    --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack" `
              "Name=instance-state-name,Values=running" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text

if (-not $instanceId -or $instanceId -eq "None") {
    Write-Host "[ERROR] Could not find running elearning instance" -ForegroundColor Red
    exit 1
}

Write-Host "Found instance: $instanceId" -ForegroundColor Green
Write-Host ""

# Run the diagnostic
Write-Host "Running diagnostics..." -ForegroundColor Yellow
$commandId = aws ssm send-command `
    --profile account-483382415631 `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "file://scripts/diagnose-backup-copy-issues.json" `
    --query "Command.CommandId" `
    --output text

Write-Host "Command ID: $commandId" -ForegroundColor Green
Write-Host "Waiting for command to complete..." -ForegroundColor Yellow

# Wait for command to complete
Start-Sleep -Seconds 5

$maxAttempts = 30
$attempt = 0
$status = ""

while ($attempt -lt $maxAttempts) {
    $status = aws ssm get-command-invocation `
        --profile account-483382415631 `
        --command-id $commandId `
        --instance-id $instanceId `
        --query "Status" `
        --output text 2>$null
    
    if ($status -eq "Success" -or $status -eq "Failed") {
        break
    }
    
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 2
    $attempt++
}

Write-Host ""
Write-Host ""

# Get the output
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "DIAGNOSTIC OUTPUT - ELEARNING" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

$output = aws ssm get-command-invocation `
    --profile account-483382415631 `
    --command-id $commandId `
    --instance-id $instanceId `
    --query "StandardOutputContent" `
    --output text

Write-Host $output

# Get errors if any
$errors = aws ssm get-command-invocation `
    --profile account-483382415631 `
    --command-id $commandId `
    --instance-id $instanceId `
    --query "StandardErrorContent" `
    --output text

if ($errors) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "ERRORS" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host $errors -ForegroundColor Red
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Diagnostic complete for elearning.tsin.ca" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

