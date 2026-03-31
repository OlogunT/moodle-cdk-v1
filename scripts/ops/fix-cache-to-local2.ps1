# Fix: Move cachestore_file from EFS to LOCAL filesystem so flock() works
$scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(@'
#!/bin/bash

echo "=== Step 1: Create local cache dirs ==="
mkdir -p /var/cache/moodle
mkdir -p /var/cache/moodlelocal
chown apache:apache /var/cache/moodle /var/cache/moodlelocal
chmod 775 /var/cache/moodle /var/cache/moodlelocal
echo "Done"

echo "=== Step 2: Update config.php ==="
php <<'PHPEOF'
<?php
$config = file_get_contents('/app/moodle/config.php');
$lines = explode("\n", $config);
$newlines = array();
foreach ($lines as $line) {
    if ((strpos($line, 'cachedir') !== false || strpos($line, 'localcachedir') !== false) && strpos($line, 'CFG') !== false) {
        echo "Removing: $line\n";
        continue;
    }
    $newlines[] = $line;
}
$config = implode("\n", $newlines);
$addLines  = '$CFG->cachedir = "/var/cache/moodle";' . "\n";
$addLines .= '$CFG->localcachedir = "/var/cache/moodlelocal";' . "\n";
$config = str_replace(
    "require_once(__DIR__ . '/lib/setup.php');",
    $addLines . "require_once(__DIR__ . '/lib/setup.php');",
    $config
);
file_put_contents('/app/moodle/config.php', $config);
echo "config.php updated\n";
PHPEOF

echo "=== Step 3: Verify ==="
grep -n 'cachedir\|lock_factory' /app/moodle/config.php || true
php -l /app/moodle/config.php 2>&1 || true

echo "=== Step 4: Clear old caches ==="
rm -rf /data/moodledata/cache/cachestore_file 2>/dev/null || true
rm -rf /data/moodledata/localcache/cachestore_file 2>/dev/null || true
rm -rf /data/moodledata/lock/* 2>/dev/null || true
rm -rf /data/moodledata/temp/lock/* 2>/dev/null || true
echo "Old cache cleared"

echo "=== Step 5: Clear DB locks ==="
php -r "define('CLI_SCRIPT',true); require('/app/moodle/config.php'); \$DB->execute('DELETE FROM {lock_db}'); echo 'DB locks cleared'.chr(10);" 2>&1 || true

echo "=== Step 6: Delete MUC config ==="
rm -f /data/moodledata/muc/config.php 2>/dev/null || true
echo "MUC config deleted"

echo "=== Step 7: Purge caches ==="
cd /app/moodle && php admin/cli/purge_caches.php 2>&1 || true
echo "Caches purged"

echo "=== Step 8: Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1 || true
echo "PHP-FPM restarted"

echo "=== Step 9: Test flock ==="
php -r "
\$f = fopen('/var/cache/moodle/test.lock', 'w');
if (flock(\$f, LOCK_EX | LOCK_NB)) {
    echo 'flock on local: YES'.chr(10);
    flock(\$f, LOCK_UN);
} else {
    echo 'flock on local: NO'.chr(10);
}
fclose(\$f);
unlink('/var/cache/moodle/test.lock');
" 2>&1 || true

echo "DONE"
'@))

$shellCmd = "echo $scriptB64 | base64 -d > /tmp/fix2.sh && bash /tmp/fix2.sh 2>&1; echo EXIT=$?"
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

