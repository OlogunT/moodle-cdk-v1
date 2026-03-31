# Fix cachestore_file lock - switch to DB lock factory + clear locks
$scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(@'
#!/bin/bash
echo "=== Step 1: Clear lock files ==="
rm -rf /data/moodledata/lock/* 2>/dev/null
rm -rf /data/moodledata/temp/lock/* 2>/dev/null
echo "Lock files cleared"

echo "=== Step 2: Clear DB locks ==="
php -r "define('CLI_SCRIPT',true); require('/app/moodle/config.php'); \$DB->execute('DELETE FROM {lock_db}'); echo 'DB locks cleared: '.\$DB->count_records('lock_db').' remaining'.chr(10);"

echo "=== Step 3: Check current config.php for lock_factory ==="
grep -n 'lock_factory' /app/moodle/config.php 2>/dev/null || echo "No lock_factory found"

echo "=== Step 4: Add db_record_lock_factory ==="
if ! grep -q 'lock_factory' /app/moodle/config.php; then
    php -r "
    \$f = file_get_contents('/app/moodle/config.php');
    \$add = '\$CFG->lock_factory = chr(92).chr(92).\"core\".chr(92).chr(92).\"lock\".chr(92).chr(92).\"db_record_lock_factory\";';
    echo 'Will add: '.\$add.chr(10);
    "
    # Use php to safely modify config.php
    php <<'PHPEOF'
<?php
$config = file_get_contents('/app/moodle/config.php');
$lockLine = '$CFG->lock_factory = "\\core\\lock\\db_record_lock_factory";' . "\n";
$config = str_replace(
    'require_once(__DIR__ . \'/lib/setup.php\');',
    $lockLine . 'require_once(__DIR__ . \'/lib/setup.php\');',
    $config
);
file_put_contents('/app/moodle/config.php', $config);
echo "config.php updated\n";
PHPEOF
else
    echo "lock_factory already in config.php"
fi

echo "=== Step 5: Verify config.php ==="
grep -n 'lock_factory' /app/moodle/config.php

echo "=== Step 6: Purge caches ==="
cd /app/moodle && php admin/cli/purge_caches.php 2>&1
echo "Caches purged"

echo "=== Step 7: Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"

echo "DONE"
'@))

$shellCmd = "echo $scriptB64 | base64 -d > /tmp/fix_lock_v3.sh && bash /tmp/fix_lock_v3.sh 2>&1 && echo EXIT=0"
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

