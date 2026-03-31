#!/usr/bin/env pwsh
Param(
  [string]$Profile  = 'tsin-account',
  [string]$Region   = 'ca-central-1',
  [string]$Instance = 'i-0c386871e2eb20f71'
)
$ErrorActionPreference = 'Stop'

$bash = @'
#!/bin/bash
echo "=== STEP 1: Kill stuck PHP processes ==="
pkill -9 -f "course/view" 2>/dev/null || true
sleep 1

echo "=== STEP 2: Clear ALL cache/lock dirs on EFS ==="
rm -rf /data/moodledata/lock/* 2>/dev/null
rm -rf /data/moodledata/temp/lock/* 2>/dev/null
find /data/moodledata/cache -type f -delete 2>/dev/null
find /data/moodledata/localcache -type f -not -path "*/lang/*" -delete 2>/dev/null
echo "Cache dirs cleared"

echo "=== STEP 3: Clear DB lock table ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$DB->execute('DELETE FROM {lock_db}');
echo 'DB locks cleared: ' . \$DB->count_records('lock_db') . ' remaining' . PHP_EOL;
" 2>&1

echo "=== STEP 4: Add db_record_lock_factory if missing ==="
if grep -q 'lock_factory' /app/moodle/config.php; then
    echo "lock_factory already set:"
    grep 'lock_factory' /app/moodle/config.php
else
    sed -i "s|require_once(__DIR__ . '/lib/setup.php');|\$CFG->lock_factory = 'core\\\\lock\\\\db_record_lock_factory';\nrequire_once(__DIR__ . '/lib/setup.php');|" /app/moodle/config.php
    echo "Added db_record_lock_factory"
    grep 'lock_factory' /app/moodle/config.php
fi
php -l /app/moodle/config.php 2>&1

echo "=== STEP 5: Purge caches via CLI ==="
cd /app/moodle && php admin/cli/purge_caches.php 2>&1
echo "CLI purge done"

echo "=== STEP 6: Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"

sleep 5
echo "=== STEP 7: Test course 70 ==="
curl -s -o /dev/null -w "HTTP:%{http_code} Time:%{time_total}s" -m 20 "https://elearning.tsin.ca/course/view.php?id=70" 2>&1
echo ""
echo "=== DONE ==="
'@

$pf = Join-Path $env:TEMP 'fix70now.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8
Write-Host "Params file written: $pf"

Write-Host "Sending SSM command to $Instance ..."
$cmdId = ((aws --profile $Profile --region $Region ssm send-command `
    --instance-ids $Instance `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text 2>&1)).Trim()
Write-Host "CommandId: $cmdId"

Write-Host "Waiting 90s..."
Start-Sleep 90

$result = aws --profile $Profile --region $Region ssm get-command-invocation `
    --command-id $cmdId --instance-id $Instance `
    --query '{S:Status,RC:ResponseCode,O:StandardOutputContent,E:StandardErrorContent}' `
    --output json 2>&1 | ConvertFrom-Json

Write-Host "Status: $($result.S)  RC: $($result.RC)"
Write-Host $result.O
if ($result.E) { Write-Host "STDERR: $($result.E)" }

