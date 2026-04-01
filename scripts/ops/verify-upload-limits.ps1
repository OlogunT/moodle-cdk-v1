Param(
  [string]$Stack = 'MoodleCdkStack',
  [string]$Region = 'ca-central-1',
  [string]$Profile = 'account-483382415631'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# Discover instances by CFN stack-name tag, then fallback to ASG name pattern
$ids = @()
$idsText = aws ec2 describe-instances --profile $Profile --region $Region `
  --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].InstanceId' --output text
if ($idsText) { $ids = $idsText -split '\s+' | Where-Object { $_ -ne '' } }

if (-not $ids -or $ids.Count -eq 0) {
  $asgJson = aws autoscaling describe-auto-scaling-groups --profile $Profile --region $Region `
    --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Inst:Instances[?LifecycleState==`InService`].InstanceId}' --output json | ConvertFrom-Json
  $matching = @($asgJson | Where-Object { $_.Name -like '*MoodleAutoScalingGroup*' })
  if ($matching) {
    foreach($g in $matching) { $ids += @($g.Inst) }
    $ids = $ids | Where-Object { $_ } | Select-Object -Unique
  }
}

if (-not $ids -or $ids.Count -eq 0) { throw "No running instances discovered for $Stack" }

Write-Host ("Instances: " + ($ids -join ', '))

foreach($id in $ids) {
  Write-Host "Verifying on $id ..."
  $cmdId = aws ssm send-command --profile $Profile --region $Region --document-name AWS-RunShellScript `
    --comment 'Verify upload limits' --instance-ids $id `
    --parameters file://scripts/ssm-verify-upload-limits.json --query 'Command.CommandId' --output text

  # Wait up to 5 minutes
  $deadline = (Get-Date).AddMinutes(5)
  $status = ''
  do {
    try {
      $inv = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $cmdId --instance-id $id --query '{Status:Status}' --output json | ConvertFrom-Json
      $status = $inv.Status
    } catch { $status = 'Pending' }
    if ($status -in 'Success','Cancelled','Failed','TimedOut') { break }
    Start-Sleep -Seconds 2
  } while((Get-Date) -lt $deadline)

  $out = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $cmdId --instance-id $id `
    --query '{StdOut:StandardOutputContent,StdErr:StandardErrorContent,Status:Status}' --output json | ConvertFrom-Json
  Write-Host "Status: $($out.Status)"
  Write-Host '--- Key lines ---'
  ($out.StdOut -split "`n") | Where-Object { $_ -match 'upload_max_filesize|post_max_size|memory_limit|LimitRequestBody|ProxyTimeout|Timeout|maxbytes' } | ForEach-Object { Write-Host $_ }
  if ($out.StdErr) { Write-Host '--- StdErr (last 10) ---'; ($out.StdErr -split "`n" | Select-Object -Last 10) | ForEach-Object { Write-Host $_ } }
}

