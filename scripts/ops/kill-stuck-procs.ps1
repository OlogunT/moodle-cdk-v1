#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "=== KILLING STUCK upgrade.php AND cron.php PROCESSES ==="
pkill -9 -f "upgrade.php" 2>&1 && echo "Killed upgrade.php" || echo "No upgrade.php to kill"
pkill -9 -f "cron.php" 2>&1 && echo "Killed cron.php processes" || echo "No cron.php to kill"

sleep 3

echo "=== VERIFYING KILLS ==="
ps aux | grep -E "upgrade\.php|cron\.php" | grep -v grep || echo "All PHP CLI processes killed"

echo "=== RESTARTING PHP-FPM ==="
systemctl restart php-fpm 2>&1 || systemctl restart php8*-fpm 2>&1 || echo "Could not restart php-fpm via systemctl"
sleep 3
ps aux | grep "php-fpm: master" | grep -v grep

echo "=== RESTARTING APACHE ==="
systemctl restart httpd 2>&1
sleep 3
systemctl is-active httpd

echo "=== CLEARING MOODLE UPGRADE LOCK FROM DB ==="
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1
echo "Upgrade lock cleared"
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning');" 2>&1

echo "=== QUICK CURL TEST (10s max) ==="
sleep 5
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 10 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'kill-stuck-procs-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Start-Sleep 35
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

