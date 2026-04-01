$ErrorActionPreference = 'Continue'
$awsProfile = 'tsin-account'
$region  = 'ca-central-1'
$i1 = 'i-08cfb0d5a27e77adb'
$i2 = 'i-00af3adb301e601f8'

Write-Host '=== STEP 1: Full config.php dump + cache purge on instance 1 (EFS writer) ==='
$id1 = (aws ssm send-command `
  --profile $awsProfile --region $region `
  --cli-input-json file://scripts/ops/ssm-fix-lockfactory-i1.json `
  --query 'Command.CommandId' --output text)
Write-Host "Command ID: $id1"
Write-Host 'Waiting 60s...'
Start-Sleep 60

Write-Host ''
Write-Host '========== INSTANCE 1 OUTPUT =========='
aws ssm get-command-invocation `
  --profile $awsProfile --region $region `
  --command-id $id1 --instance-id $i1 `
  --query '{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}' `
  --output json

Write-Host ''
Write-Host '=== STEP 2: Restart php-fpm on instance 2 to flush OPcache ==='
$id2 = (aws ssm send-command `
  --profile $awsProfile --region $region `
  --cli-input-json file://scripts/ops/ssm-restart-instance2.json `
  --query 'Command.CommandId' --output text)
Write-Host "Command ID: $id2"
Write-Host 'Waiting 20s...'
Start-Sleep 20

Write-Host ''
Write-Host '========== INSTANCE 2 OUTPUT =========='
aws ssm get-command-invocation `
  --profile $awsProfile --region $region `
  --command-id $id2 --instance-id $i2 `
  --query '{Status:Status,Out:StandardOutputContent}' `
  --output json

Write-Host ''
Write-Host '=== ALB Health ==='
$resp = Invoke-WebRequest -Uri 'https://elearning.tsin.ca/health' -UseBasicParsing -TimeoutSec 10
Write-Host "elearning.tsin.ca/health -> HTTP $($resp.StatusCode)"

