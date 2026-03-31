#!/usr/bin/env pwsh
Param(
  [string]$Profile  = 'tsin-account',
  [string]$Region   = 'ca-central-1',
  [string]$Instance = 'i-0c386871e2eb20f71'
)
$pf = Join-Path $env:TEMP 'restart-apache-now.json'
$cmdId = ((aws --profile $Profile --region $Region ssm send-command `
    --instance-ids $Instance `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text 2>&1)).Trim()
Write-Host "CMD:$cmdId"
$cmdId | Set-Content (Join-Path $env:TEMP 'last-cmd-id.txt')

