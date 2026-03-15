#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "STEP1: Kill ALL PHP CLI processes"
pkill -9 -f "cron.php" 2>&1 || true
pkill -9 -f "upgrade.php" 2>&1 || true
pkill -9 -f "purge_caches" 2>&1 || true
sleep 2

echo "STEP2: Disable cron completely"
crontab -u apache -r 2>&1 || true
echo "Cron removed"
crontab -u apache -l 2>&1 || echo "No crontab (good)"

echo "STEP3: Restart services"
systemctl restart php-fpm 2>&1
systemctl restart httpd 2>&1
sleep 5

echo "STEP4: Check processes"
ps aux | grep -E "php.*cli" | grep -v grep || echo "No PHP CLI processes"

echo "STEP5: Clear DB locks"
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1
echo "Lock cleared"

echo "STEP6: Test"
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 15 http://localhost/login/index.php 2>&1

echo "DONE"
'@

$paramsFile = Join-Path $env:TEMP 'emergency-fix-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 30
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

