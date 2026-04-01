Param()
$ErrorActionPreference='Stop'

$region='ca-central-1'
# Get running Training instance IDs and normalize into an array
$idsText = aws ec2 describe-instances --region $region --filters Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text | Out-String
$idsArr = $idsText -split "[\s`t`r`n]+" | Where-Object { $_ -and $_.StartsWith('i-') }
if (-not $idsArr -or $idsArr.Count -eq 0) { throw 'No running instances for TrainingMoodleCdkStack' }
Write-Host ("Instances: {0}" -f ($idsArr -join ', '))

$cmdId = aws ssm send-command --region $region --document-name AWS-RunShellScript --comment 'Fix wwwroot for Training' --instance-ids $idsArr --parameters file://scripts/ssm-fix-training-wwwroot.json --query 'Command.CommandId' --output text
Write-Host "CommandId: $cmdId"

$deadline = (Get-Date).AddMinutes(8)
$status = @{}

Do {
  Start-Sleep -Seconds 8
  foreach($id in $idsArr) {
    if ($status[$id] -eq 'Success') { continue }
    try {
      $inv = aws ssm get-command-invocation --region $region --command-id $cmdId --instance-id $id --output json | ConvertFrom-Json
      $status[$id] = $inv.Status
    } catch {
      $status[$id] = 'Pending'
    }
  }
  $values = @($status.Values)
  $allDone = $values -and ($values -notcontains 'InProgress') -and ($values -notcontains 'Pending') -and ($values -notcontains 'Delayed')
} Until ($allDone -or (Get-Date) -gt $deadline)

$outs = @()
foreach($id in $idsArr) {
  $inv = aws ssm get-command-invocation --region $region --command-id $cmdId --instance-id $id --query '{InstanceId:InstanceId,Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' --output json | ConvertFrom-Json
  $outs += $inv
}

$outs | ConvertTo-Json -Compress

