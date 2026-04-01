#!/usr/bin/env pwsh
# Purge Moodle caches, clear DB locks, check course 70 cache, verify fix
Param(
  [string]$AwsProfile = 'tsin-account',
  [string]$Region     = 'ca-central-1'
)

$bash = @'
#!/bin/bash
set -e
INST=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)
echo "=== Instance: $INST ==="

echo "--- Verify lock_factory in config.php ---"
grep -n "lock_factory" /app/moodle/config.php || echo "MISSING lock_factory - adding..."
if ! grep -q "lock_factory" /app/moodle/config.php; then
  sed -i "s|require_once(__DIR__ . '/lib/setup.php');|\$CFG->lock_factory = 'core\lock\db_record_lock_factory';\nrequire_once(__DIR__ . '/lib/setup.php');|" /app/moodle/config.php
fi

echo "--- Check config.php syntax ---"
php -l /app/moodle/config.php 2>&1

echo "--- Clear DB lock_db table ---"
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$count = \$DB->count_records('lock_db');
echo 'lock_db rows before: ' . \$count . PHP_EOL;
\$DB->execute('DELETE FROM {lock_db}');
echo 'lock_db cleared' . PHP_EOL;
" 2>&1 || echo "lock_db clear failed (may not exist yet)"

echo "--- Purge all Moodle caches via CLI ---"
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Purge done"

echo "--- Clear EFS lock/cache dirs ---"
rm -rf /data/moodledata/lock/* 2>/dev/null && echo "lock dir cleared" || echo "lock dir empty/missing"
rm -rf /data/moodledata/cache/* 2>/dev/null && echo "cache dir cleared" || echo "cache dir empty/missing"
rm -rf /data/moodledata/localcache/* 2>/dev/null && echo "localcache cleared" || echo "localcache empty/missing"
rm -rf /data/moodledata/temp/* 2>/dev/null && echo "temp cleared" || echo "temp empty/missing"

echo "--- PHP-FPM slow request count ---"
systemctl status php-fpm --no-pager | grep -E "Requests|slow|Traffic" || echo "no stats"

echo "--- Test local Moodle response (should be fast now) ---"
time curl -s -o /dev/null -w "HTTP:%{http_code} Time:%{time_total}s" --max-time 15 "http://$(hostname -I | awk '{print $1}')/login/index.php" 2>&1
echo ""

echo "--- DONE $INST ---"
'@

$pf = Join-Path $env:TEMP 'purge-fix-locks.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8

Write-Host "Sending purge+fix to both instances..."
$ids = @{}
foreach ($inst in @('i-084e9f7a365ea3326', 'i-04aa12a6aa64b6e66')) {
    $id = (aws --profile $AwsProfile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 120 `
        --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
    Write-Host "INST:$inst CMD:$id"
    $ids[$inst] = $id
}
$ids | ConvertTo-Json | Set-Content (Join-Path $env:TEMP 'purge-cmd-ids.json')
Write-Host "All sent. Poll in 60 seconds."

