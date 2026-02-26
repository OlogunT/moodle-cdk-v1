#!/usr/bin/env pwsh

$instanceId = "i-011c65cd247389ee6"
Write-Host "Sending course size check command..." -ForegroundColor Yellow

$commandId = aws ssm send-command --profile account-483382415631 --instance-ids $instanceId --document-name "AWS-RunShellScript" --parameters "file://scripts/check-course-sizes.json" --query "Command.CommandId" --output text

Write-Host "Command ID: $commandId" -ForegroundColor Green
Write-Host "Waiting for results..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

$output = aws ssm get-command-invocation --profile account-483382415631 --command-id $commandId --instance-id $instanceId --query "StandardOutputContent" --output text

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "COURSE SIZE CHECK RESULTS" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host $output

