#!/usr/bin/env pwsh
# Gentle restart - no killing, just systemctl restart + diagnostics
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1'
)

$bash = @'
#!/bin/bash
INST=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)
echo "=== Instance: $INST ==="

echo "--- config.php syntax ---"
php -l /app/moodle/config.php 2>&1

echo "--- lock_factory status ---"
grep -n "lock_factory" /app/moodle/config.php || echo "MISSING lock_factory"

echo "--- Ensure lock_factory is set ---"
if ! grep -q "lock_factory" /app/moodle/config.php; then
  sed -i "s|require_once(__DIR__ . '/lib/setup.php');|\$CFG->lock_factory = 'core\\lock\\db_record_lock_factory';\nrequire_once(__DIR__ . '/lib/setup.php');|" /app/moodle/config.php
  echo "Added lock_factory"
fi

echo "--- PHP-FPM status before ---"
systemctl is-active php-fpm && echo "php-fpm active" || echo "php-fpm INACTIVE"

echo "--- httpd status before ---"
systemctl is-active httpd && echo "httpd active" || echo "httpd INACTIVE"

echo "--- Soft restart PHP-FPM (not kill) ---"
systemctl restart php-fpm
sleep 2
systemctl is-active php-fpm && echo "php-fpm OK" || echo "php-fpm FAILED"

echo "--- Soft restart httpd ---"
systemctl restart httpd
sleep 2
systemctl is-active httpd && echo "httpd OK" || echo "httpd FAILED"

echo "--- Apache listening ports ---"
ss -tlnp | grep -E "httpd|:80" || echo "no port 80 listener"

echo "--- PHP-FPM listening ---"
ss -tlnp | grep -E "php-fpm|9000" || ss -xlnp | grep php-fpm || echo "php-fpm socket check"

echo "--- Apache config test ---"
httpd -t 2>&1 | tail -5

echo "--- PHP-FPM config test ---"
php-fpm -t 2>&1 | tail -5

echo "--- Apache error log last 20 lines ---"
tail -20 /var/log/httpd/error_log 2>/dev/null || tail -20 /var/log/httpd/ssl_error_log 2>/dev/null || echo "no apache error log"

echo "--- Local curl test ---"
curl -v --max-time 8 http://127.0.0.1/ 2>&1 | head -30

echo "--- DONE $INST ---"
'@

$pf = Join-Path $env:TEMP 'gentle-restart.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8
Write-Host "Sending gentle restart to both instances..."

foreach ($inst in @('i-084e9f7a365ea3326', 'i-04aa12a6aa64b6e66')) {
    $id = (aws --profile $Profile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 60 `
        --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
    Write-Host "INST:$inst CMD:$id"
    $id | Add-Content (Join-Path $env:TEMP "gentle-$inst.txt")
}
Write-Host "All sent. Poll in 40s."

