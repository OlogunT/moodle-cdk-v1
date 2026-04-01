#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== CHECKING WHAT UPGRADE IS PENDING ==="
$DB -e "SELECT name, value FROM mdl_config WHERE name IN ('version','upgraderunning','rolesactive');" 2>&1
$DB -e "SELECT plugin, name, value FROM mdl_config_plugins WHERE name='version' AND CAST(value AS DECIMAL(20,2)) > 0 ORDER BY plugin;" 2>&1 | head -40

echo "=== CLEARING STUCK upgraderunning FLAG (if any) ==="
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1
echo "Done"

echo "=== RUNNING MOODLE UPGRADE CLI ==="
php /app/moodle/admin/cli/upgrade.php --non-interactive 2>&1
echo "Upgrade exit: $?"

echo "=== CHECKING UPGRADE STATUS AFTER ==="
$DB -e "SELECT name, value FROM mdl_config WHERE name IN ('version','upgraderunning');" 2>&1

echo "=== RUNNING CRON TO VERIFY IT IS NO LONGER SUSPENDED ==="
timeout 20 php /app/moodle/admin/cli/cron.php 2>&1 | head -5
echo "Cron exit: $?"

echo "=== PURGING CACHES AGAIN ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Purge exit: $?"

echo "=== TESTING LOGIN PAGE RESPONSE TIME ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 60 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'run-moodle-upgrade-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 180 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Write-Host "Waiting 150s for upgrade to complete..."
Start-Sleep 150
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

