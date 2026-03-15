#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"

echo "=== Fix DB version to correct value ==="
$DB -e "UPDATE mdl_config SET value='2025041402.10' WHERE name='version';" 2>&1
echo "Updated to 2025041402.10"

echo "=== Verify ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== Run upgrade.php to recalc allversionshash ==="
timeout 60 php /app/moodle/admin/cli/upgrade.php --non-interactive 2>&1
echo "Upgrade exit: $?"

echo "=== Verify after upgrade ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== Purge caches ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Purge exit: $?"

echo "=== Test login speed ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== Re-enable cron ==="
echo "* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1" | crontab -u apache - 2>&1
crontab -u apache -l 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'fix-dbver-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Write-Host "Waiting 90s..."
Start-Sleep 90
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

