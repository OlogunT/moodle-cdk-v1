Param(
  [string]$Region = "ca-central-1"
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$idsText = aws ec2 describe-instances --region $Region `
  --filters Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack `
  Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].InstanceId' --output text

if (-not $idsText) { throw "No running instances for TrainingMoodleCdkStack." }
$idsArr = $idsText -split "\s+" | Where-Object { $_ -ne '' }
Write-Host "Instances: $($idsArr -join ', ')"

$cmdId = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
  --comment "Hotfix Menutopic deprecation" --instance-ids $idsArr `
  --parameters file://scripts/ssm-hotfix-menutopic-deprecation.json `
  --query 'Command.CommandId' --output text
Write-Host "CommandId: $cmdId"

Start-Sleep -Seconds 5
$outs = aws ssm list-command-invocations --region $Region --command-id $cmdId --details `
  --query 'CommandInvocations[].{InstanceId:InstanceId,Status:Status,StdOut:CommandPlugins[0].Output,StdErr:CommandPlugins[0].StandardErrorUrl}' --output json | ConvertFrom-Json
$outs | ConvertTo-Json -Compress

