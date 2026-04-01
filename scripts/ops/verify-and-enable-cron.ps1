#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "=== localcache contents ==="
find /data/moodledata/localcache -type f 2>/dev/null | head -20 || echo "No cache files"
ls -la /data/moodledata/localcache/ 2>&1

echo "=== Verify login speed via HTTPS ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 15 https://elearning.tsin.ca/login/index.php 2>&1
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 15 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== Run upgrade check (without full upgrade) ==="
timeout 30 php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once('/app/moodle/lib/upgradelib.php');
echo 'Core requires upgrade: ' . (moodle_needs_upgrading() ? 'YES' : 'NO') . PHP_EOL;
" 2>&1
echo "PHP exit: $?"

echo "=== Re-enable cron ==="
echo "* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1" | crontab -u apache - 2>&1
crontab -u apache -l 2>&1

echo "=== DB state ==="
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'verify-cron-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 50
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

