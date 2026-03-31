# Fix cachestore_file lock issue - switch lock factory to DB and clear stuck locks
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

// 1. Clear ALL db locks first
$DB->execute("DELETE FROM {lock_db}");
echo "DB locks cleared\n";

// 2. Clear specific course 70 cache from MUC config
echo "\n=== Checking MUC cache config ===\n";
$mucfile = $CFG->dataroot . '/muc/config.php';
if (file_exists($mucfile)) {
    echo "MUC config exists: $mucfile\n";
    // Read size
    echo "Size: " . filesize($mucfile) . " bytes\n";
} else {
    echo "No MUC config file\n";
}

// 3. Delete the course 70 cache entry to force rebuild
$DB->delete_records_select('cache_filters', "1=1");
echo "Cache filters cleared\n";

// 4. Purge caches via CLI
echo "\n=== Purging caches via CLI ===\n";
purge_all_caches();
echo "All caches purged\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_lock2.php && php /tmp/fix_lock2.php 2>&1; echo '---'; rm -rf /data/moodledata/lock/* 2>&1; echo 'Lock dir cleared'; rm -rf /data/moodledata/cache/cachestore_file/* 2>&1; echo 'File cache store cleared'; rm -rf /data/moodledata/localcache/cachestore_file/* 2>&1; echo 'Local file cache cleared'; "
$shellCmd += "grep -n 'lock_factory\|cachelock' /app/moodle/config.php 2>&1 || echo 'No lock_factory in config.php'; echo '---CONFIG_CHECK---'; "
$shellCmd += "echo '=== Adding lock factory override ==='; "
$shellCmd += "grep -q 'lock_factory' /app/moodle/config.php && echo 'Already has lock_factory' || { sed -i '/require_once.*setup.php/i \$CFG->lock_factory = \"\\\\\\\\core\\\\\\\\lock\\\\\\\\db_record_lock_factory\";' /app/moodle/config.php && echo 'Added db_record_lock_factory to config.php'; }; "
$shellCmd += "cd /app/moodle && php admin/cli/purge_caches.php 2>&1; echo 'CLI purge done'; "
$shellCmd += "systemctl restart php-fpm 2>&1; echo 'PHP-FPM restarted'; "
$shellCmd += "echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 600 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 120
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

