Param(
  [Parameter(Mandatory=$true)][string]$Stack,
  [string]$Region = "ca-central-1"
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Wait-SSM {
  Param([string]$CommandId, [string[]]$InstanceIds, [string]$Region, [int]$TimeoutSeconds = 600)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $statuses = @{}
  do {
    foreach($id in $InstanceIds) {
      if ($statuses.ContainsKey($id) -and $statuses[$id] -in 'Success','Cancelled','Failed','TimedOut') { continue }
      try {
        $inv = aws ssm get-command-invocation --region $Region --command-id $CommandId --instance-id $id --query '{InstanceId:InstanceId,Status:Status}' --output json | ConvertFrom-Json
        $statuses[$id] = $inv.Status
      } catch { $statuses[$id] = 'Unknown' }
    }
    $pending = $statuses.GetEnumerator() | Where-Object { $_.Value -notin 'Success','Cancelled','Failed','TimedOut' }
    if (-not $pending) { break }
    Start-Sleep -Seconds 3
  } while((Get-Date) -lt $deadline)
  return $statuses
}

# Discover instances by stack name (fallback to Project tag for Prod if needed)
$idsText = aws ec2 describe-instances --region $Region `
  --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack `
  Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].InstanceId' --output text
if (-not $idsText) {
  # Some environments do not carry the CFN stack-name tag on instances. Fallback by project tag.
  $idsText = aws ec2 describe-instances --region $Region `
    --filters Name=tag:Project,Values=Moodle-CDK `
    Name=instance-state-name,Values=running `
    --query 'Reservations[].Instances[].InstanceId' --output text
}
if (-not $idsText) { throw "No running instances for $Stack (and no Moodle-CDK instances found)." }
$instances = $idsText -split "\s+" | Where-Object { $_ -ne '' }
$leader = ($instances | Sort-Object)[0]
Write-Host "Instances: $($instances -join ', ')"
Write-Host "Leader: $leader"

# Phase A: Enable maintenance + stop services on ALL nodes
$cmdA = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
  --comment "Maintenance stop services (all)" --instance-ids $instances `
  --parameters file://scripts/ssm-maintenance-stop.json --query 'Command.CommandId' --output text
Write-Host "Phase A CommandId: $cmdA"
$stA = Wait-SSM -CommandId $cmdA -InstanceIds $instances -Region $Region -TimeoutSeconds 300
$stA | Format-Table -AutoSize | Out-String | Write-Host

# Phase B: Replace plugin on LEADER only
$cmdB = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
  --comment "Menutopic replace (leader)" --instance-ids $leader `
  --parameters file://scripts/ssm-menutopic-replace-leader.json --query 'Command.CommandId' --output text
Write-Host "Phase B CommandId: $cmdB"
$stB = Wait-SSM -CommandId $cmdB -InstanceIds @($leader) -Region $Region -TimeoutSeconds 600
$stB | Format-Table -AutoSize | Out-String | Write-Host

# Phase C: Upgrade + purge on LEADER only
$cmdC = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
  --comment "Upgrade+purge (leader)" --instance-ids $leader `
  --parameters file://scripts/ssm-upgrade-purge.json --query 'Command.CommandId' --output text
Write-Host "Phase C CommandId: $cmdC"
$stC = Wait-SSM -CommandId $cmdC -InstanceIds @($leader) -Region $Region -TimeoutSeconds 600
$stC | Format-Table -AutoSize | Out-String | Write-Host

# Phase D: Start services + disable maintenance on ALL nodes
$cmdD = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
  --comment "Start services & disable maintenance (all)" --instance-ids $instances `
  --parameters file://scripts/ssm-start-disable-maintenance.json --query 'Command.CommandId' --output text
Write-Host "Phase D CommandId: $cmdD"
$stD = Wait-SSM -CommandId $cmdD -InstanceIds $instances -Region $Region -TimeoutSeconds 300
$stD | Format-Table -AutoSize | Out-String | Write-Host

# Summary
$summary = [PSCustomObject]@{
  PhaseA = ($stA.GetEnumerator() | ForEach-Object { "${($_.Key)}:${($_.Value)}" }) -join ', '
  PhaseB = ($stB.GetEnumerator() | ForEach-Object { "${($_.Key)}:${($_.Value)}" }) -join ', '
  PhaseC = ($stC.GetEnumerator() | ForEach-Object { "${($_.Key)}:${($_.Value)}" }) -join ', '
  PhaseD = ($stD.GetEnumerator() | ForEach-Object { "${($_.Key)}:${($_.Value)}" }) -join ', '
}
$summary | ConvertTo-Json -Compress

