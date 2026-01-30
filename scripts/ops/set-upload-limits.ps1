Param(
  [string]$Stack = 'ALL',
  [string]$Region = 'ca-central-1',
  [string]$Profile = 'account-483382415631'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Wait-SSM {
  Param(
    [Parameter(Mandatory=$true)][string]$CommandId,
    [Parameter(Mandatory=$true)][string[]]$InstanceIds,
    [Parameter(Mandatory=$true)][string]$Region,
    [Parameter(Mandatory=$true)][string]$Profile,
    [int]$TimeoutSeconds = 900
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $statuses = @{}
  do {
    foreach($id in $InstanceIds) {
      if ($statuses.ContainsKey($id) -and $statuses[$id] -in 'Success','Cancelled','Failed','TimedOut') { continue }
      try {
        $inv = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $CommandId --instance-id $id --query '{InstanceId:InstanceId,Status:Status}' --output json | ConvertFrom-Json
        $statuses[$id] = $inv.Status
      } catch { $statuses[$id] = 'Unknown' }
    }
    $pending = $statuses.GetEnumerator() | Where-Object { $_.Value -notin 'Success','Cancelled','Failed','TimedOut' }
    if (-not $pending) { break }
    Start-Sleep -Seconds 3
  } while((Get-Date) -lt $deadline)
  return $statuses
}

function Get-SSMOutput {
  Param(
    [Parameter(Mandatory=$true)][string]$CommandId,
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [Parameter(Mandatory=$true)][string]$Region,
    [Parameter(Mandatory=$true)][string]$Profile
  )
  try {
    $out = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $CommandId --instance-id $InstanceId --query '{StdOut:StandardOutputContent,StdErr:StandardErrorContent,Status:Status}' --output json | ConvertFrom-Json
    return $out
  } catch {
    return $null
  }
}

function Get-InstanceIdsForStack {
  Param(
    [Parameter(Mandatory=$true)][string]$Stack,
    [Parameter(Mandatory=$true)][string]$Region,
    [Parameter(Mandatory=$true)][string]$Profile
  )
  # 1) Prefer CFN stack-name tag
  $idsText = aws ec2 describe-instances --profile $Profile --region $Region `
    --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack `
    Name=instance-state-name,Values=running `
    --query 'Reservations[].Instances[].InstanceId' --output text

  $ids = @()
  if ($idsText) { $ids = $idsText -split "\s+" | Where-Object { $_ -ne '' } }

  if (-not $ids -or $ids.Count -eq 0) {
    # 2) Fallback: identify by ASG name patterns (PowerShell filtering to avoid JMESPath quoting issues)
    $asgNamePattern = if ($Stack -match 'Training') { 'TrainingMoodleAutoScalingGroup' } else { 'MoodleAutoScalingGroup' }
    $asgJson = aws autoscaling describe-auto-scaling-groups --profile $Profile --region $Region `
      --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Instances:Instances[?LifecycleState==`InService`].InstanceId}' --output json | ConvertFrom-Json
    $matching = @($asgJson | Where-Object { $_.Name -like "*${asgNamePattern}*" })
    if ($matching) {
      $ids = @()
      foreach($m in $matching) { $ids += @($m.Instances) }
      $ids = $ids | Where-Object { $_ -ne $null -and $_ -ne '' } | Select-Object -Unique
    }
  }

  if (-not $ids -or $ids.Count -eq 0) {
    # 3) Last resort: project tag (updates all Moodle-CDK instances)
    $idsText3 = aws ec2 describe-instances --profile $Profile --region $Region `
      --filters Name=tag:Project,Values=Moodle-CDK Name=instance-state-name,Values=running `
      --query 'Reservations[].Instances[].InstanceId' --output text
    if ($idsText3) { $ids = $idsText3 -split "\s+" | Where-Object { $_ -ne '' } }
  }

  return $ids
}

function Apply-UploadLimits {
  Param(
    [Parameter(Mandatory=$true)][string[]]$InstanceIds,
    [Parameter(Mandatory=$true)][string]$Region,
    [Parameter(Mandatory=$true)][string]$Profile
  )
  foreach($id in $InstanceIds) {
    Write-Host "Applying upload limits (1 GiB) on $id ..."
    $cmdId = aws ssm send-command --profile $Profile --region $Region --document-name AWS-RunShellScript `
      --comment "Set 1GiB upload limits (rolling)" --instance-ids $id `
      --parameters file://scripts/ssm-set-upload-limits.json --query 'Command.CommandId' --output text

    $st = Wait-SSM -CommandId $cmdId -InstanceIds @($id) -Region $Region -Profile $Profile -TimeoutSeconds 900
    $status = $st[$id]
    $out = Get-SSMOutput -CommandId $cmdId -InstanceId $id -Region $Region -Profile $Profile
    Write-Host "Instance $id status: $status"
    if ($out) {
      Write-Host "--- StdOut (key lines) ---"
      ($out.StdOut -split "`n") | Where-Object { $_ -match 'upload_max_filesize|post_max_size|memory_limit|ProxyTimeout|Timeout|LimitRequestBody|maxbytes' } | ForEach-Object { Write-Host $_ }
      if ($out.StdErr) {
        Write-Host "--- StdErr (last 10) ---"; ($out.StdErr -split "`n" | Select-Object -Last 10) | ForEach-Object { Write-Host $_ }
      }
    }
  }
}

if ($Stack -eq 'ALL') {
  $stacks = @('TrainingMoodleCdkStack','MoodleCdkStack')
} else {
  $stacks = @($Stack)
}

foreach($s in $stacks) {
  Write-Host "=== Processing stack: $s ==="
  $ids = Get-InstanceIdsForStack -Stack $s -Region $Region -Profile $Profile
  if (-not $ids -or $ids.Count -eq 0) {
    throw "No running instances discovered for $s"
  }
  Write-Host ("Instances: " + ($ids -join ', '))
  Apply-UploadLimits -InstanceIds $ids -Region $Region -Profile $Profile
}

Write-Host "Done. Upload limits applied."
