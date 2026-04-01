Param(
  [string]$Region = "ca-central-1",
  [string[]]$InstanceIds
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

if (-not $InstanceIds -or $InstanceIds.Count -eq 0) {
  throw "Provide -InstanceIds to target"
}

$cmdId = aws ssm send-command --region $Region --document-name AWS-RunShellScript --comment "Finalize Menutopic swap" --instance-ids $InstanceIds --parameters file://scripts/ssm-finish-menutopic-swap.json --query 'Command.CommandId' --output text
Write-Host "CommandId: $cmdId"

Start-Sleep -Seconds 5
$outs = @()
foreach($id in $InstanceIds) {
  $inv = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $id --query '{InstanceId:InstanceId,Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' --output json | ConvertFrom-Json
  $outs += $inv
}
$outs | ConvertTo-Json -Compress

