# Clear all stale DB locks that are blocking cache lock acquisition
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. Current DB locks ===\n";
$alllocks = $DB->count_records('lock_db');
echo "Total DB locks: $alllocks\n";

echo "\n=== 2. Clear ALL expired locks ===\n";
$now = time();
$expired = $DB->count_records_select('lock_db', 'expires < ?', [$now]);
echo "Expired locks (expires < $now): $expired\n";
if ($expired > 0) {
    $DB->delete_records_select('lock_db', 'expires < ?', [$now]);
    echo "Deleted $expired expired locks\n";
}

echo "\n=== 3. Clear ALL locks (force) ===\n";
$remaining = $DB->count_records('lock_db');
echo "Remaining locks: $remaining\n";
if ($remaining > 0) {
    // Force clear all - these are stale from a stuck cron
    $DB->delete_records('lock_db');
    echo "Force-deleted all $remaining remaining locks\n";
}

echo "\n=== 4. Verify ===\n";
$final = $DB->count_records('lock_db');
echo "Final lock count: $final\n";

echo "\n=== 5. Test lock acquisition ===\n";
$lockfactory = \core\lock\lock_config::get_lock_factory('cachelock');
echo "Lock factory: " . get_class($lockfactory) . "\n";
$lock = $lockfactory->get_lock('test_cache_lock', 5);
if ($lock) {
    echo "Lock acquired OK\n";
    $lock->release();
    echo "Lock released OK\n";
} else {
    echo "FAILED to acquire lock\n";
}

echo "\n=== 6. Purge caches ===\n";
purge_all_caches();
echo "Caches purged\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/clear_db_locks.php && php /tmp/clear_db_locks.php 2>&1 && systemctl restart php-fpm 2>&1 && echo 'PHP-FPM restarted' && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 120
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

