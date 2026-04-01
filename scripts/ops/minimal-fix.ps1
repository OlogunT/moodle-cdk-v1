#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
# Kill any stuck processes first
pkill -9 -f "upgrade.php" 2>&1 || true
pkill -9 -f "cron.php" 2>&1 || true
sleep 2

CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"

# Fix the DB version (it got mangled)
$DB -e "UPDATE mdl_config SET value='2025041402.10' WHERE name='version';" 2>&1
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1

# Verify
echo "=== DB State ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

# Restart services
systemctl restart php-fpm 2>&1
sleep 3

# Quick test
echo "=== Speed Test 1 ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1
echo "=== Speed Test 2 (cached) ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== Cron status ==="
crontab -u apache -l 2>&1
echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'minimal-fix-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 40
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

