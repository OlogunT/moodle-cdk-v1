#!/usr/bin/env pwsh
Param(
  [string]$Profile  = 'tsin-account',
  [string]$Region   = 'ca-central-1',
  [string]$Instance = 'i-0c386871e2eb20f71'
)
$ErrorActionPreference = 'Stop'

$bash = @'
#!/bin/bash
CONFIG="/app/moodle/config.php"

echo "=== Current lines around lock_factory ==="
grep -n "lock_factory" "$CONFIG" || echo "none found"

echo ""
echo "=== Line 44-50 of config.php ==="
sed -n '44,50p' "$CONFIG"

echo ""
echo "=== Backing up config.php ==="
cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"
echo "Backed up"

echo ""
echo "=== Fixing config.php: remove broken lock_factory lines, add clean one ==="
php -r "
\$content = file_get_contents('$CONFIG');

// Remove ALL existing lock_factory lines (including broken/partial ones)
\$lines = explode(PHP_EOL, \$content);
\$cleaned = array();
foreach (\$lines as \$line) {
    if (strpos(\$line, 'lock_factory') !== false || strpos(\$line, '_lock_factory') !== false) {
        echo 'Removing line: ' . \$line . PHP_EOL;
        continue;
    }
    \$cleaned[] = \$line;
}
\$content = implode(PHP_EOL, \$cleaned);

// Insert clean lock_factory line before require_once setup.php
\$needle = \"require_once(__DIR__ . '/lib/setup.php');\";
\$insert = \"\\\$CFG->lock_factory = 'core\\\\\\\\lock\\\\\\\\db_record_lock_factory';\" . PHP_EOL;
\$content = str_replace(\$needle, \$insert . \$needle, \$content);

file_put_contents('$CONFIG', \$content);
echo 'config.php fixed' . PHP_EOL;
" 2>&1

echo ""
echo "=== Verify syntax ==="
php -l "$CONFIG" 2>&1

echo ""
echo "=== Verify lock_factory line ==="
grep -n "lock_factory" "$CONFIG"

echo ""
echo "=== Now clear all cache/lock files ==="
rm -rf /data/moodledata/lock/* 2>/dev/null
rm -rf /data/moodledata/temp/lock/* 2>/dev/null
find /data/moodledata/cache -type f -delete 2>/dev/null
find /data/moodledata/localcache -type f -not -path "*/lang/*" -delete 2>/dev/null
echo "Cache cleared"

echo ""
echo "=== Clear DB locks ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$DB->execute('DELETE FROM {lock_db}');
echo 'DB locks cleared: ' . \$DB->count_records('lock_db') . ' remaining' . PHP_EOL;
" 2>&1

echo ""
echo "=== Purge caches ==="
cd /app/moodle && php admin/cli/purge_caches.php 2>&1
echo "Purge done"

echo ""
echo "=== Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"

sleep 5
echo ""
echo "=== Test login page ==="
curl -s -o /dev/null -w "login HTTP:%{http_code} Time:%{time_total}s" -m 20 "https://elearning.tsin.ca/login/index.php" 2>&1
echo ""
echo "=== Test course 70 ==="
curl -s -o /dev/null -w "course70 HTTP:%{http_code} Time:%{time_total}s" -m 20 "https://elearning.tsin.ca/course/view.php?id=70" 2>&1
echo ""
echo "=== DONE ==="
'@

$pf = Join-Path $env:TEMP 'fix-config-php.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8
Write-Host "Sending SSM to $Instance ..."

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

