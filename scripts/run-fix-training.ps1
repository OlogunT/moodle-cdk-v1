#!/usr/bin/env pwsh
# Quick fix for training backup issues

$ErrorActionPreference = "Stop"

Write-Host "Finding training instance..." -ForegroundColor Yellow
$instanceId = aws ec2 describe-instances --profile account-483382415631 --filters "Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text

Write-Host "Instance: $instanceId" -ForegroundColor Green
Write-Host "Sending command..." -ForegroundColor Yellow

$commandId = aws ssm send-command --profile account-483382415631 --instance-ids $instanceId --document-name "AWS-RunShellScript" --parameters "file://scripts/fix-backup-simple.json" --query "Command.CommandId" --output text

Write-Host "Command ID: $commandId" -ForegroundColor Green
Write-Host ""
Write-Host "To check status, run:" -ForegroundColor Yellow
Write-Host "aws ssm get-command-invocation --profile account-483382415631 --command-id $commandId --instance-id $instanceId" -ForegroundColor Cyan

