Param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack"
)

$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# Find running instances for the specified stack
$idsText = aws ec2 describe-instances --region $Region --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text | Out-String
$idsArr = $idsText -split "[\s`t`r`n]+" | Where-Object { $_ -and $_.StartsWith('i-') }
if (-not $idsArr -or $idsArr.Count -eq 0) { throw "No running instances for $Stack" }
Write-Host ("Instances: {0}" -f ($idsArr -join ', '))

# Send SSM command that updates the Menutopic plugin
$cmdId = aws ssm send-command --region $Region --document-name AWS-RunShellScript --comment "Update Menutopic course format" --instance-ids $idsArr --parameters file://scripts/ssm-update-menutopic.json --query 'Command.CommandId' --output text
Write-Host "CommandId: $cmdId"

# Wait up to 12 minutes for completion
$deadline = (Get-Date).AddMinutes(12)
$status = @{}
Do {
  Start-Sleep -Seconds 10
  foreach($id in $idsArr) {
    if ($status[$id] -eq 'Success') { continue }
    try {
      $inv = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $id --output json | ConvertFrom-Json
      $status[$id] = $inv.Status
    } catch {
      $status[$id] = 'Pending'
    }
  }
  $values = @($status.Values)
  $allDone = $values -and ($values -notcontains 'InProgress') -and ($values -notcontains 'Pending') -and ($values -notcontains 'Delayed')
} Until ($allDone -or (Get-Date) -gt $deadline)

# Collect outputs
$outs = @()
foreach($id in $idsArr) {
  $inv = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $id --query '{InstanceId:InstanceId,Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' --output json | ConvertFrom-Json
  $outs += $inv
}

$outs | ConvertTo-Json -Compress

