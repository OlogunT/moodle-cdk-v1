#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "=== CLIMAINTENANCE FILE ==="
ls -la /app/moodle/climaintenance.html 2>/dev/null && echo "MAINTENANCE FILE EXISTS" || echo "No climaintenance.html (good)"

echo "=== MOODLE WWWROOT ==="
grep -m1 "CFG->wwwroot" /app/moodle/config.php 2>/dev/null

echo "=== PHP MAX EXECUTION TIME ==="
php -r "echo ini_get('max_execution_time');" 2>/dev/null

echo "=== PHP-FPM POOL CONFIG (timeouts) ==="
grep -E "request_terminate_timeout|pm\." /etc/php-fpm.d/*.conf 2>/dev/null || grep -E "request_terminate_timeout|pm\." /etc/php*/fpm/pool.d/*.conf 2>/dev/null

echo "=== APACHE TIMEOUT CONFIG ==="
grep -r "^Timeout\|ProxyTimeout" /etc/httpd/conf/ /etc/httpd/conf.d/ 2>/dev/null

echo "=== RECENT APACHE ACCESS LOG (last 10) ==="
tail -10 /var/log/httpd/access_log 2>/dev/null || tail -10 /var/log/httpd/ssl_access_log 2>/dev/null || echo "No access log found"

echo "=== MOODLE UPGRADE PENDING CHECK ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
echo 'DB version: ' . get_config('', 'version') . PHP_EOL;
" 2>&1 | head -10

echo "=== MOODLE DATAROOT SESSIONS ==="
ls /app/moodledata/sessions/ 2>/dev/null | wc -l || echo "Cannot access sessions dir"

echo "=== MOODLE LOCALCACHE ==="
du -sh /app/moodledata/localcache/ 2>/dev/null || echo "No localcache dir"

echo "=== CURL TEST TO LOCALHOST LOGIN ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 10 http://localhost/login/index.php 2>&1
'@

$paramsFile = Join-Path $env:TEMP 'check-moodle-timeouts-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Start-Sleep 20
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

