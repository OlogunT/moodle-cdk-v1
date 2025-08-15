param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "Region: $Region  Stack: $Stack"

# Locate a running instance from this stack
$descJson = aws ec2 describe-instances --region $Region --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack Name=instance-state-name,Values=running
$desc = $descJson | ConvertFrom-Json
$instanceId = $null
foreach ($r in $desc.Reservations) {
  foreach ($i in $r.Instances) { if ($i.InstanceId) { $instanceId = $i.InstanceId; break } }
  if ($instanceId) { break }
}
if (-not $instanceId) { throw "No running instance found in stack $Stack" }
Write-Host "InstanceId: $instanceId"

# Send the collector command
$paramPath = Join-Path $PSScriptRoot 'ssm-collect-500.json'
if (-not (Test-Path $paramPath)) { throw "Missing $paramPath" }
$cmdId = aws ssm send-command --region $Region --instance-ids $instanceId --document-name AWS-RunShellScript --parameters file://$paramPath --query "Command.CommandId" --output text
Write-Host "CmdId: $cmdId"

# Poll for completion
$status = ""; $tries = 0
while ($true) {
  Start-Sleep -Seconds 6
  $tries++
  $inv = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --output json | ConvertFrom-Json
  $status = $inv.Status
  Write-Host "Status: $status (try $tries)"
  if ($status -notin @('Pending','InProgress','Delayed')) { break }
  if ($tries -ge 30) { break }
}

# Save outputs
$outDir = Join-Path $PSScriptRoot 'outputs'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stdoutPath = Join-Path $outDir '500-diag-stdout.txt'
$stderrPath = Join-Path $outDir '500-diag-stderr.txt'
[System.IO.File]::WriteAllText($stdoutPath, $inv.StandardOutputContent, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($stderrPath, $inv.StandardErrorContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "==== FINAL STATUS ===="
Write-Host $status
Write-Host "STDOUT saved to: $stdoutPath"
Write-Host "STDERR saved to: $stderrPath"

# Print a few key lines directly for convenience
$lines = $inv.StandardOutputContent -split "`n"
$preview = $lines | Select-Object -First 60
Write-Host "==== STDOUT (preview) ===="
$preview -join "`n"
