#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "=== NGINX STATUS ==="
systemctl is-active nginx 2>&1 || service nginx status 2>&1 | head -5

echo "=== PHP-FPM STATUS ==="
systemctl is-active php*-fpm 2>&1 || ps aux | grep php-fpm | grep -v grep | head -5

echo "=== PHP-FPM PROCESSES ==="
ps aux | grep php-fpm | grep -v grep | wc -l

echo "=== NGINX ERROR LOG (last 20 lines) ==="
tail -20 /var/log/nginx/error.log 2>/dev/null || tail -20 /var/log/nginx/error_log 2>/dev/null || echo "No nginx error log found"

echo "=== PHP-FPM LOG (last 20 lines) ==="
find /var/log -name "*.log" | xargs grep -l "fpm\|php" 2>/dev/null | head -3 | xargs tail -20 2>/dev/null || echo "No php-fpm log found"

echo "=== DISK USAGE ==="
df -h / 2>&1

echo "=== MEMORY USAGE ==="
free -m 2>&1

echo "=== LOAD AVERAGE ==="
uptime 2>&1

echo "=== LOCAL HTTP CHECK ==="
curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" http://localhost/ 2>&1 || echo "curl failed"

echo "=== MOODLE MAINTENANCE MODE ==="
php /app/moodle/admin/cli/maintenance.php --status 2>&1 || echo "Could not check maintenance mode"
'@

$paramsFile = Join-Path $env:TEMP 'check-server-health-params.json'
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

