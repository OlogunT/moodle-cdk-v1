#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
echo "=== Kill any stuck PHP CLI ==="
pkill -9 -f "upgrade.php" 2>&1 || true
pkill -9 -f "cron.php" 2>&1 || true
sleep 2

CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"

echo "=== Clear DB locks ==="
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1
echo "Done"

echo "=== Check DB version ==="
$DB -sN -e "SELECT CONCAT(name,'=',value) FROM mdl_config WHERE name='version';" 2>&1

echo "=== Check disk version ==="
grep '^\$version' /app/moodle/version.php

echo "=== Force update DB version to match disk ==="
DISK_VER=$(grep '^\$version' /app/moodle/version.php | sed "s/[^0-9.]//g" | head -1)
echo "Disk version: $DISK_VER"
$DB -e "UPDATE mdl_config SET value='$DISK_VER' WHERE name='version';" 2>&1
echo "Updated"

echo "=== Recalculate allversionshash via PHP ==="
timeout 30 php -r "
define('CLI_SCRIPT', true);
define('ABORT_AFTER_CONFIG', true);
require('/app/moodle/config.php');
require_once('/app/moodle/lib/setuplib.php');
require_once('/app/moodle/lib/moodlelib.php');
echo 'Config loaded' . PHP_EOL;
" 2>&1 || echo "PHP config load timed out"

echo "=== Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
sleep 3
echo "Restarted"

echo "=== Test login speed ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== DB state ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'force-fix-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Write-Host "Waiting 60s..."
Start-Sleep 60
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

