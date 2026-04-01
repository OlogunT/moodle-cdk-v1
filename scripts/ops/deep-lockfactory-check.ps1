$ErrorActionPreference = 'Continue'
$awsProfile = 'tsin-account'
$region  = 'ca-central-1'
$i1 = 'i-08cfb0d5a27e77adb'
$i2 = 'i-00af3adb301e601f8'

Write-Host '=== Sending deep lock_factory diagnostic to BOTH instances ==='
$id = (aws ssm send-command `
  --profile $awsProfile --region $region `
  --cli-input-json file://scripts/ops/ssm-deep-lockfactory-check.json `
  --query 'Command.CommandId' --output text)

Write-Host "Command ID: $id"
Write-Host 'Waiting 35 seconds...'
Start-Sleep 35

Write-Host ''
Write-Host '========== INSTANCE 1 (EFS writer) =========='
aws ssm get-command-invocation `
  --profile $awsProfile --region $region `
  --command-id $id --instance-id $i1 `
  --query 'StandardOutputContent' --output text

Write-Host ''
Write-Host '--- INSTANCE 1 STDERR ---'
aws ssm get-command-invocation `
  --profile $awsProfile --region $region `
  --command-id $id --instance-id $i1 `
  --query 'StandardErrorContent' --output text

Write-Host ''
Write-Host '========== INSTANCE 2 =========='
aws ssm get-command-invocation `
  --profile $awsProfile --region $region `
  --command-id $id --instance-id $i2 `
  --query 'StandardOutputContent' --output text

Write-Host ''
Write-Host '--- INSTANCE 2 STDERR ---'
aws ssm get-command-invocation `
  --profile $awsProfile --region $region `
  --command-id $id --instance-id $i2 `
  --query 'StandardErrorContent' --output text

