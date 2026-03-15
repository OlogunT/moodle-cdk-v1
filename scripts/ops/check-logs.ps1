#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "=== PHP-FPM ERROR LOG ==="
tail -30 /var/log/php-fpm/www-error.log 2>/dev/null || echo "No error log"

echo "=== PHP-FPM SLOW LOG ==="
tail -30 /var/log/php-fpm/www-slow.log 2>/dev/null || echo "No slow log"

echo "=== APACHE ERROR LOG ==="
tail -20 /var/log/httpd/error_log 2>/dev/null || echo "No httpd error log"

echo "=== APACHE ACCESS LOG (recent) ==="
tail -10 /var/log/httpd/access_log 2>/dev/null || echo "No access log"

echo "=== DB CONNECTIVITY TEST ==="
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
time mariadb -h $H -u $U -p$P -D $N --connect-timeout=5 -e "SELECT 1 as test;" 2>&1

echo "=== DB SLOW QUERIES ==="
mariadb -h $H -u $U -p$P -D $N --connect-timeout=5 -e "SHOW PROCESSLIST;" 2>&1

echo "=== PHP-FPM STATUS ==="
curl -s http://localhost/php-fpm-status 2>&1 || echo "No FPM status"

echo "=== PHP-FPM WORKERS ==="
ps aux | grep "php-fpm" | grep -v grep | wc -l
ps aux | grep "php-fpm.*pool" | grep -v grep

echo "=== MEMORY/CPU ==="
free -m | head -3
uptime

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'check-logs-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 30 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 15
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

