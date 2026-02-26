Param(
  [string]$Stack = 'MoodleCdkStack',
  [string]$Region = 'ca-central-1',
  [string]$Profile = 'tsin-account'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# Discover instances by CFN stack-name, else fallback to ASG name pattern
$ids = @()
$idsText = aws ec2 describe-instances --profile $Profile --region $Region `
  --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].InstanceId' --output text
if ($idsText) { $ids = $idsText -split '\s+' | Where-Object { $_ -ne '' } }

if (-not $ids -or $ids.Count -eq 0) {
  $asgAll = aws autoscaling describe-auto-scaling-groups --profile $Profile --region $Region --output json | ConvertFrom-Json
  $groups = @($asgAll.AutoScalingGroups | Where-Object { $_.AutoScalingGroupName -like '*MoodleAutoScalingGroup*' })
  if ($groups) {
    foreach($g in $groups) {
      $inService = @($g.Instances | Where-Object { $_.LifecycleState -eq 'InService' } | ForEach-Object { $_.InstanceId })
      if ($inService) { $ids += $inService }
    }
    $ids = $ids | Where-Object { $_ } | Select-Object -Unique
  }
}

if (-not $ids -or $ids.Count -eq 0) { throw "No running instances discovered for $Stack" }

Write-Host ("Instances: " + ($ids -join ', '))

foreach($id in $ids) {
  Write-Host "Querying DB maxbytes on $id ..."
  $cmdId = aws ssm send-command --profile $Profile --region $Region --document-name AWS-RunShellScript `
    --comment 'Query Moodle maxbytes via DB' --instance-ids $id `
    --parameters file://scripts/ssm-db-maxbytes.json --query 'Command.CommandId' --output text

  # Wait up to 3 minutes
  $deadline = (Get-Date).AddMinutes(3)
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
  $val = ($out.StdOut -split "`n") | Where-Object { $_ -match '^maxbytes=' } | Select-Object -First 1
  Write-Host ("$id -> $val")
  if ($out.StdErr) { Write-Host '--- StdErr (last 5) ---'; ($out.StdErr -split "`n" | Select-Object -Last 5) | ForEach-Object { Write-Host $_ } }
}

