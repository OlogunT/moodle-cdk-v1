# Fix: Move cachestore_file from EFS to LOCAL filesystem so flock() works
$scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(@'
#!/bin/bash
set -e

echo "=== Step 1: Create local cache directories ==="
mkdir -p /var/cache/moodle
mkdir -p /var/cache/moodlelocal
chown apache:apache /var/cache/moodle /var/cache/moodlelocal
chmod 775 /var/cache/moodle /var/cache/moodlelocal
echo "Local dirs created"

echo "=== Step 2: Update config.php ==="
php <<'PHPEOF'
<?php
$config = file_get_contents('/app/moodle/config.php');

// Remove any existing cachedir/localcachedir/lock_factory lines
$lines = explode("\n", $config);
$newlines = array();
foreach ($lines as $line) {
    if (strpos($line, 'cachedir') !== false && strpos($line, 'CFG') !== false) {
        echo "Removing: $line\n";
        continue;
    }
    if (strpos($line, 'localcachedir') !== false && strpos($line, 'CFG') !== false) {
        echo "Removing: $line\n";
        continue;
    }
    $newlines[] = $line;
}
$config = implode("\n", $newlines);

// Add cachedir and localcachedir pointing to LOCAL filesystem (not EFS)
$addLines  = '$CFG->cachedir = "/var/cache/moodle";' . "\n";
$addLines .= '$CFG->localcachedir = "/var/cache/moodlelocal";' . "\n";

$config = str_replace(
    "require_once(__DIR__ . '/lib/setup.php');",
    $addLines . "require_once(__DIR__ . '/lib/setup.php');",
    $config
);

file_put_contents('/app/moodle/config.php', $config);
echo "config.php updated with local cache paths\n";
PHPEOF

echo "=== Step 3: Verify config.php ==="
grep -n 'cachedir\|lock_factory' /app/moodle/config.php

echo "=== Step 4: Test PHP syntax ==="
php -l /app/moodle/config.php 2>&1

echo "=== Step 5: Clear old EFS cache ==="
rm -rf /data/moodledata/cache/cachestore_file 2>/dev/null
rm -rf /data/moodledata/localcache/cachestore_file 2>/dev/null  
rm -rf /data/moodledata/lock/* 2>/dev/null
rm -rf /data/moodledata/temp/lock/* 2>/dev/null
echo "Old cache cleared"

echo "=== Step 6: Clear DB locks ==="
php -r "define('CLI_SCRIPT',true); require('/app/moodle/config.php'); \$DB->execute('DELETE FROM {lock_db}'); echo 'DB locks: '.\$DB->count_records('lock_db').' remaining'.chr(10);"

echo "=== Step 7: Delete MUC config to force rebuild ==="
rm -f /data/moodledata/muc/config.php 2>/dev/null
echo "MUC config deleted"

echo "=== Step 8: Purge caches ==="
cd /app/moodle && php admin/cli/purge_caches.php 2>&1
echo "Caches purged"

echo "=== Step 9: Verify new cache uses local dir ==="
ls -la /var/cache/moodle/ 2>/dev/null | head -10
echo "---"
ls -la /var/cache/moodlelocal/ 2>/dev/null | head -10

echo "=== Step 10: Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"

echo "=== Step 11: Test flock on local dir ==="
php -r "
\$f = fopen('/var/cache/moodle/test.lock', 'w');
if (flock(\$f, LOCK_EX | LOCK_NB)) {
    echo 'flock works on /var/cache/moodle: YES'.chr(10);
    flock(\$f, LOCK_UN);
} else {
    echo 'flock works on /var/cache/moodle: NO'.chr(10);
}
fclose(\$f);
unlink('/var/cache/moodle/test.lock');
"

echo "DONE"
'@))

$shellCmd = "echo $scriptB64 | base64 -d > /tmp/fix_cache_local.sh && bash /tmp/fix_cache_local.sh 2>&1 && echo EXIT=0"
$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 60
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

