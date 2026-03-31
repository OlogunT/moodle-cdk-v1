#!/usr/bin/env pwsh
# Restart PHP-FPM on both instances and test local HTTP response
Param(
  [string]$AwsProfile = 'tsin-account',
  [string]$Region     = 'ca-central-1'
)

$bash = @'
#!/bin/bash
INST=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)
echo "=== Instance: $INST ==="

echo "--- lock_factory in config.php ---"
grep -n "lock_factory" /app/moodle/config.php || echo "MISSING"

echo "--- require_once count ---"
grep -c "require_once" /app/moodle/config.php

echo "--- Redis host ---"
REDIS_HOST=$(grep "session_redis_host" /app/moodle/config.php | head -1 | sed "s/.*= '//;s/';.*//")
echo "Redis: $REDIS_HOST"

echo "--- Test Redis port ---"
timeout 5 bash -c "echo PING | nc -w 3 $REDIS_HOST 6379" 2>&1 | head -3 && echo "Redis TCP OK" || echo "Redis TCP FAILED"

echo "--- Restart PHP-FPM ---"
systemctl restart php-fpm 2>&1
sleep 4
systemctl is-active php-fpm && echo "php-fpm active" || echo "php-fpm FAILED"

echo "--- Test local HTTP ---"
INST_IP=$(hostname -I | awk '{print $1}')
curl -s -o /dev/null -w "HTTP:%{http_code} Time:%{time_total}s" --max-time 12 "http://$INST_IP/login/index.php"
echo ""
echo "--- DONE $INST ---"
'@

$pf = Join-Path $env:TEMP 'restart-and-test.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8

$cmdIds = @{}
foreach ($inst in @('i-084e9f7a365ea3326', 'i-04aa12a6aa64b6e66')) {
    $id = (aws --profile $AwsProfile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 60 `
        --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
    Write-Host "INST:$inst CMD:$id"
    $cmdIds[$inst] = $id
}
$cmdIds | ConvertTo-Json | Set-Content (Join-Path $env:TEMP 'restart-test-ids.json')
Write-Host "All sent. Poll in 30s."

