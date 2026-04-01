#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
MOODLE_URL="https://elearning.tsin.ca"

echo "=== ALB IDLE TIMEOUT CHECK ==="
# Check from Apache config perspective
grep -r "Timeout\|KeepAlive" /etc/httpd/conf/httpd.conf 2>/dev/null | head -10

echo "=== MOODLE SESSION HANDLER ==="
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('sessionhandler','sessiontimeout','upgraderunning');" 2>&1

echo "=== WARMING UP MOODLE CACHES (hitting real URL) ==="
echo "Hitting login page..."
curl -s -o /tmp/moodle-warmup-login.txt -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 90 -L "$MOODLE_URL/login/index.php" 2>&1
echo "First 200 chars of response:"
head -c 200 /tmp/moodle-warmup-login.txt 2>/dev/null

echo "=== WARMING UP CACHE VIA PHP CLI ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
echo 'Moodle version: ' . \$CFG->version . PHP_EOL;
echo 'wwwroot: ' . \$CFG->wwwroot . PHP_EOL;
// Trigger theme/cache rebuild
\$cache = cache::make('core', 'config');
echo 'Cache OK' . PHP_EOL;
" 2>&1

echo "=== MOODLE CRON (run once to rebuild) ==="
timeout 30 php /app/moodle/admin/cli/cron.php 2>&1 | head -20 || echo "Cron timed out or errored (that's OK)"

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'warmup-moodle-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Write-Host "Waiting 90s for warmup to complete..."
Start-Sleep 90
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

