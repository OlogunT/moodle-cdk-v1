#!/usr/bin/env pwsh
param(
  [string]$Region = "ca-central-1",
  [string]$AwsProfile
)


# Optional: set AWS profile for CLI calls in this session
if ($AwsProfile) { $env:AWS_PROFILE = $AwsProfile }

$ErrorActionPreference = 'Stop'

function Get-InstanceIdsByStack([string]$stackName) {
  $idsText = aws ec2 describe-instances `
    --region $Region `
    --filters Name=tag:aws:cloudformation:stack-name,Values=$stackName Name=instance-state-name,Values=running `
    --query 'Reservations[].Instances[].InstanceId' `
    --output text
  if (-not $idsText) { return @() }
  return $idsText -split "\s+" | Where-Object { $_ -and $_ -like 'i-*' }
}

function Invoke-SSMShellDoc([string[]]$InstanceIds, [string]$DocPath, [string]$Label){
  if (-not $InstanceIds -or $InstanceIds.Count -eq 0) {
    Write-Host "[$Label] No running instances" -ForegroundColor Yellow
    return
  }
  $cmdId = aws ssm send-command `
    --region $Region `
    --document-name AWS-RunShellScript `
    --parameters file://$DocPath `
    --instance-ids $InstanceIds `
    --query Command.CommandId `
    --output text
  Write-Host "[$Label] CommandId: $cmdId" -ForegroundColor Gray
  foreach ($iid in $InstanceIds) {
    # wait for completion
    $tries=0
    do {
      Start-Sleep -Seconds 2
      $status = aws ssm get-command-invocation `
        --region $Region `
        --command-id $cmdId `
        --instance-id $iid `
        --query Status `
        --output text 2>$null
      $tries++
    } while ($status -notin @('Success','Failed','Cancelled','TimedOut') -and $tries -lt 60)

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "[$Label] Instance: $iid  Status: $status" -ForegroundColor Cyan
    aws ssm get-command-invocation `
      --region $Region `
      --command-id $cmdId `
      --instance-id $iid `
      --query StandardOutputContent `
      --output text
    $stderr = aws ssm get-command-invocation `
      --region $Region `
      --command-id $cmdId `
      --instance-id $iid `
      --query StandardErrorContent `
      --output text 2>$null
    if ($stderr) {
      Write-Host "--- STDERR ---" -ForegroundColor Yellow
      Write-Host $stderr
    }
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
  }
}

Write-Host "Discovering instances..." -ForegroundColor Cyan
$learningIds = Get-InstanceIdsByStack 'MoodleCdkStack'
$trainingIds = Get-InstanceIdsByStack 'TrainingMoodleCdkStack'
Write-Host ("Learning instances: {0}" -f ($learningIds -join ', ')) -ForegroundColor Gray
Write-Host ("Training instances: {0}" -f ($trainingIds -join ', ')) -ForegroundColor Gray

# SMTP check
Invoke-SSMShellDoc -InstanceIds $learningIds -DocPath 'scripts/ssm-check-smtp.json' -Label 'LEARNING SMTP'
Invoke-SSMShellDoc -InstanceIds $trainingIds -DocPath 'scripts/ssm-check-smtp.json' -Label 'TRAINING SMTP'

# Redis verification
if (Test-Path 'scripts/ssm-verify-redis-learning.json') {
  Invoke-SSMShellDoc -InstanceIds $learningIds -DocPath 'scripts/ssm-verify-redis-learning.json' -Label 'LEARNING REDIS'
}
if (Test-Path 'scripts/ssm-verify-redis-config.json') {
  Invoke-SSMShellDoc -InstanceIds $trainingIds -DocPath 'scripts/ssm-verify-redis-config.json' -Label 'TRAINING REDIS'
}

# Cron check
Invoke-SSMShellDoc -InstanceIds $learningIds -DocPath 'scripts/ssm-check-cron.json' -Label 'LEARNING CRON'
Invoke-SSMShellDoc -InstanceIds $trainingIds -DocPath 'scripts/ssm-check-cron.json' -Label 'TRAINING CRON'

Write-Host "Done." -ForegroundColor Green

