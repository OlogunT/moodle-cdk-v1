$ErrorActionPreference = 'Continue'
$profile = 'tsin-account'
$region = 'ca-central-1'
$i1 = 'i-08cfb0d5a27e77adb'
$i2 = 'i-00af3adb301e601f8'

Write-Host '=== Sending verify command to both instances ==='
$id = (aws ssm send-command --profile $profile --region $region `
  --cli-input-json file://scripts/ops/ssm-verify-lockfactory.json `
  --query 'Command.CommandId' --output text)
Write-Host "Command ID: $id"

Write-Host 'Waiting 25 seconds for command to complete...'
Start-Sleep 25

Write-Host ''
Write-Host '=== INSTANCE 1 (EFS writer) ==='
aws ssm get-command-invocation --profile $profile --region $region `
  --command-id $id --instance-id $i1 `
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' `
  --output json

Write-Host ''
Write-Host '=== INSTANCE 2 ==='
aws ssm get-command-invocation --profile $profile --region $region `
  --command-id $id --instance-id $i2 `
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' `
  --output json

Write-Host ''
Write-Host '=== ALB health check ==='
$resp = Invoke-WebRequest -Uri 'https://elearning.tsin.ca/health' -UseBasicParsing -TimeoutSec 10
Write-Host "elearning.tsin.ca/health -> HTTP $($resp.StatusCode)"

