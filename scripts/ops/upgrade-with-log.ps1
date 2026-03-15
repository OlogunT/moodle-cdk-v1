#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

# Step 1: Start upgrade in background, redirect to log file
$bash1 = @'
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1

nohup php /app/moodle/admin/cli/upgrade.php --non-interactive > /tmp/upgrade-log.txt 2>&1 &
echo "PID: $!"
echo "Upgrade started in background"
'@

$paramsFile = Join-Path $env:TEMP 'upgrade-bg-params.json'
@{ commands = @($bash1) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Starting upgrade in background..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 30 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 10
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status)"
Write-Host $result.StandardOutputContent

# Step 2: Wait and check progress
Write-Host "`nWaiting 60s then checking progress..."
Start-Sleep 60

$bash2 = @'
echo "=== UPGRADE PROCESS STATUS ==="
ps aux | grep "upgrade.php" | grep -v grep || echo "Not running"
echo "=== LOG FILE (last 50 lines) ==="
tail -50 /tmp/upgrade-log.txt 2>/dev/null || echo "No log file"
echo "=== LOG FILE SIZE ==="
ls -la /tmp/upgrade-log.txt 2>/dev/null
'@

$paramsFile2 = Join-Path $env:TEMP 'check-upgrade-params.json'
@{ commands = @($bash2) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile2 -Encoding UTF8

$cmdId2 = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile2" --timeout-seconds 30 `
  --query 'Command.CommandId' --output text)).Trim()
Start-Sleep 15
$result2 = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId2 --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "`nProgress check - Status: $($result2.Status)"
Write-Host $result2.StandardOutputContent

