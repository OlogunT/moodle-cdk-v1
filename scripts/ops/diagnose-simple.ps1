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
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== DB CONFIG FLAGS ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','release','upgraderunning','allversionshash','cachelock_file_default_lock') ORDER BY name;" 2>&1

echo "=== MENUTOPIC PLUGIN VERSION IN DB ==="
$DB -e "SELECT plugin,name,value FROM mdl_config_plugins WHERE plugin='format_menutopic';" 2>&1

echo "=== MENUTOPIC DISK VERSION ==="
grep 'version' /app/moodle/course/format/menutopic/version.php 2>/dev/null || echo "No version.php found"

echo "=== CORE VERSION FROM version.php ==="
grep -E '^\$version|^\$release' /app/moodle/version.php | head -5

echo "=== ANY STUCK PHP PROCS ==="
ps aux | grep -E "upgrade\.php|cron\.php" | grep -v grep || echo "None"

echo "=== CURL LOGIN (30s max) ==="
time curl -s -o /dev/null -w "HTTP: %{http_code} Size: %{size_download} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== CURL LOCAL LOGIN (30s max) ==="
time curl -s -o /dev/null -w "HTTP: %{http_code} Size: %{size_download} Time: %{time_total}s\n" -m 30 http://localhost/login/index.php 2>&1

echo "=== PHP-FPM SLOW LOG ==="
cat /var/log/php-fpm/www-slow.log 2>/dev/null | tail -30 || echo "No slow log"

echo "=== MOODLE ERROR LOG (last 10 lines) ==="
tail -10 /app/moodledata/moodle.log 2>/dev/null || echo "No moodle.log"

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'diag-simple-params.json'
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

