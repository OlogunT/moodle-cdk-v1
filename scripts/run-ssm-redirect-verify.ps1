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

# Send the redirect verification SSM command
$paramPath = Join-Path $PSScriptRoot 'ssm-verify-http-redirects.json'
if (-not (Test-Path $paramPath)) { throw "Missing $paramPath" }
$cmdId = aws ssm send-command --region $Region --instance-ids $instanceId --document-name AWS-RunShellScript --parameters file://$paramPath --query "Command.CommandId" --output text
Write-Host "CmdId: $cmdId"

# Wait and fetch
Start-Sleep -Seconds 15
$inv = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --output json | ConvertFrom-Json

# Save outputs
$outDir = Join-Path $PSScriptRoot 'outputs'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stdoutPath = Join-Path $outDir 'redirect-verify-stdout.txt'
$stderrPath = Join-Path $outDir 'redirect-verify-stderr.txt'
[System.IO.File]::WriteAllText($stdoutPath, $inv.StandardOutputContent, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($stderrPath, $inv.StandardErrorContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "Status: $($inv.Status)"
Write-Host "STDOUT saved to: $stdoutPath"
Write-Host "STDERR saved to: $stderrPath"

# Quick summary parse
$txt = $inv.StandardOutputContent
$localhostLine = ($txt | Select-String -Pattern "--- LOCALHOST ---" -Context 0,1).Context.PostContext | Select-Object -First 1
$albLine       = ($txt | Select-String -Pattern "--- ALB ---" -Context 0,1).Context.PostContext | Select-Object -First 1
Write-Host ("LOCALHOST: {0}" -f $localhostLine)
Write-Host ("ALB:       {0}" -f $albLine)

