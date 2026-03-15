#!/usr/bin/env pwsh
# Install and configure cron on elearning.tsin.ca

Param(
    [string]$Profile = 'tsin-account'
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Installing Cron - ELEARNING" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Finding elearning instance..." -ForegroundColor Yellow
$instanceId = aws ec2 describe-instances --profile $Profile --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text

Write-Host "Instance: $instanceId" -ForegroundColor Green
Write-Host "Installing cron..." -ForegroundColor Yellow

$commandId = aws ssm send-command --profile $Profile --instance-ids $instanceId --document-name "AWS-RunShellScript" --parameters "file://scripts/install-cron.json" --query "Command.CommandId" --output text

Write-Host "Command ID: $commandId" -ForegroundColor Green
Write-Host "Waiting for installation to complete..." -ForegroundColor Yellow

Start-Sleep -Seconds 10

$maxAttempts = 30
$attempt = 0

while ($attempt -lt $maxAttempts) {
    $status = aws ssm get-command-invocation --profile $Profile --command-id $commandId --instance-id $instanceId --query "Status" --output text 2>$null
    
    if ($status -eq "Success" -or $status -eq "Failed") {
        break
    }
    
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 2
    $attempt++
}

Write-Host ""
Write-Host ""

$output = aws ssm get-command-invocation --profile $Profile --command-id $commandId --instance-id $instanceId --query "StandardOutputContent" --output text

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "INSTALLATION OUTPUT" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host $output

$errors = aws ssm get-command-invocation --profile $Profile --command-id $commandId --instance-id $instanceId --query "StandardErrorContent" --output text

if ($errors) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "ERRORS" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host $errors -ForegroundColor Red
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "Cron installation complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Moodle cron is now running every minute." -ForegroundColor Yellow
Write-Host "Backups and course copies should now work properly." -ForegroundColor Yellow

