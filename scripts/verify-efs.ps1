param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
# Ensure UTF-8 to avoid charmap issues
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "Region: $Region  Stack: $Stack"

function Get-InstanceIdFromStack {
  param([string]$Region,[string]$Stack)
  $descJson = aws ec2 describe-instances --region $Region --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack Name=instance-state-name,Values=running
  $desc = $descJson | ConvertFrom-Json
  foreach ($r in ($desc.Reservations | Where-Object { $_.Instances })) {
    foreach ($i in $r.Instances) { if ($i.InstanceId) { return $i.InstanceId } }
  }
  return $null
}

function Get-InstanceIdFromAsg {
  param([string]$Region)
  $asgs = aws autoscaling describe-auto-scaling-groups --region $Region | ConvertFrom-Json
  $asg = $asgs.AutoScalingGroups | Where-Object { $_.AutoScalingGroupName -like '*MoodleAutoScalingGroup*' } | Select-Object -First 1
  if (-not $asg) { return $null }
  $iid = aws ec2 describe-instances --region $Region --filters Name=tag:aws:autoscaling:groupName,Values=$($asg.AutoScalingGroupName) Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].InstanceId" --output text
  if ($iid -and $iid -ne 'None') { return $iid }
  return $null
}

function Get-InstanceIdFromTargetGroup {
  param([string]$Region)
  $tgs = aws elbv2 describe-target-groups --region $Region | ConvertFrom-Json
  $tg = $tgs.TargetGroups | Where-Object { $_.TargetGroupName -like 'Moodle*' } | Select-Object -First 1
  if (-not $tg) { return $null }
  $th = aws elbv2 describe-target-health --region $Region --target-group-arn $tg.TargetGroupArn | ConvertFrom-Json
  $id = $th.TargetHealthDescriptions[0].Target.Id
  if ($id) { return $id }
  return $null
}

$instanceId = Get-InstanceIdFromStack -Region $Region -Stack $Stack
if (-not $instanceId) { $instanceId = Get-InstanceIdFromAsg -Region $Region }
if (-not $instanceId) { $instanceId = Get-InstanceIdFromTargetGroup -Region $Region }
if (-not $instanceId) { throw "No running instance found via Stack/ASG/TargetGroup discovery" }

Write-Host "InstanceId: $instanceId"

# Build and send SSM command (using a prewritten JSON file with safe commands)
$paramPath = Join-Path $PSScriptRoot 'ssm-verify-min.json'
if (-not (Test-Path $paramPath)) { throw "Missing $paramPath" }

$cmdId = aws ssm send-command --region $Region --instance-ids $instanceId --document-name AWS-RunShellScript --parameters file://$paramPath --query "Command.CommandId" --output text
Write-Host "CmdId: $cmdId"

# Poll for completion (text output to avoid JSON/encoding issues)
$status = ""
$maxWait = 180
$waited = 0
while ($true) {
  Start-Sleep -Seconds 6
  $waited += 6
  $status = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --query "Status" --output text
  Write-Host "Status: $status (waited ${waited}s)"
  if ($status -notin @('Pending','InProgress','Delayed')) { break }
  if ($waited -ge $maxWait) { break }
}

Write-Host "==== FINAL STATUS ===="
Write-Host $status

# Retrieve outputs as text and save to UTF-8 files to avoid console encoding issues
$stdoutText = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --query "StandardOutputContent" --output text
$stderrText = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --query "StandardErrorContent" --output text
$outDir = Join-Path $PSScriptRoot 'outputs'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stdoutPath = Join-Path $outDir 'last-stdout.txt'
$stderrPath = Join-Path $outDir 'last-stderr.txt'
[System.IO.File]::WriteAllText($stdoutPath, $stdoutText, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($stderrPath, $stderrText, [System.Text.UTF8Encoding]::new($false))

# Print a short ASCII summary parsed from stdout
$summary = 'unknown'
if ($stdoutText -match 'app:mounted') { $app='mounted' } else { $app='not' }
if ($stdoutText -match 'data:mounted') { $data='mounted' } else { $data='not' }
$summary = "app=$app data=$data"
Write-Host "SUMMARY: $summary"
Write-Host "STDOUT saved to: $stdoutPath"
Write-Host "STDERR saved to: $stderrPath"

