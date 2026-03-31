# Fix the lock_factory line in config.php - wrong escaping
$scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(@'
#!/bin/bash

echo "=== Current lock_factory line ==="
grep -n 'lock_factory' /app/moodle/config.php

echo "=== Fixing lock_factory syntax ==="
php <<'PHPEOF'
<?php
$config = file_get_contents('/app/moodle/config.php');

// Remove any existing lock_factory lines
$lines = explode("\n", $config);
$newlines = array();
foreach ($lines as $line) {
    if (strpos($line, 'lock_factory') !== false) {
        echo "Removing: $line\n";
        continue;
    }
    $newlines[] = $line;
}
$config = implode("\n", $newlines);

// Add correct lock_factory line before require_once setup.php
$correctLine = '$CFG->lock_factory = "\\\\core\\\\lock\\\\db_record_lock_factory";' . "\n";
$config = str_replace(
    "require_once(__DIR__ . '/lib/setup.php');",
    $correctLine . "require_once(__DIR__ . '/lib/setup.php');",
    $config
);

file_put_contents('/app/moodle/config.php', $config);
echo "Config updated\n";
PHPEOF

echo "=== Verify new line ==="
grep -n 'lock_factory' /app/moodle/config.php

echo "=== Test PHP syntax ==="
php -l /app/moodle/config.php 2>&1

echo "=== Test lock factory resolves ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
echo 'lock_factory = ' . \$CFG->lock_factory . chr(10);
\$class = \$CFG->lock_factory;
echo 'class_exists = ' . (class_exists(\$class) ? 'yes' : 'no') . chr(10);
"

echo "=== Clear DB locks ==="
php -r "define('CLI_SCRIPT',true); require('/app/moodle/config.php'); \$DB->execute('DELETE FROM {lock_db}'); echo 'cleared'.chr(10);"

echo "=== Purge caches ==="
cd /app/moodle && php admin/cli/purge_caches.php 2>&1

echo "=== Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "Done"
'@))

$shellCmd = "echo $scriptB64 | base64 -d > /tmp/fix_syntax.sh && bash /tmp/fix_syntax.sh 2>&1 && echo EXIT=0"
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

