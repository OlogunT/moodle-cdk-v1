# Setup a cron job on the EC2 instance to automatically clean stale DB locks every 5 minutes
$phpScript = @'
<?php
// /app/moodle/local/cleanup_stale_locks.php
// Automatically cleans stale DB locks that accumulate from stuck cron/PHP processes
define('CLI_SCRIPT', true);
require(__DIR__ . '/../config.php');

$now = time();
$stale_threshold = $now - 600; // locks older than 10 minutes are stale

// 1. Delete expired locks
$expired = $DB->count_records_select('lock_db', 'expires < ?', [$now]);
if ($expired > 0) {
    $DB->delete_records_select('lock_db', 'expires < ?', [$now]);
}

// 2. Delete locks with no owner that are older than threshold
$orphaned = $DB->count_records_select('lock_db', "owner = '' AND expires < ?", [$now + 300]);
if ($orphaned > 0) {
    $DB->delete_records_select('lock_db', "owner = '' AND expires < ?", [$now + 300]);
}

// 3. If total locks exceed 100, force clear all (sign of a stuck cron)
$total = $DB->count_records('lock_db');
if ($total > 100) {
    $DB->delete_records('lock_db');
    $total = 0;
}

// Log only if something was cleaned
$cleaned = $expired + $orphaned;
if ($cleaned > 0 || $total > 100) {
    error_log("cleanup_stale_locks: cleared expired=$expired orphaned=$orphaned total_remaining=$total");
}
'@

$b64Script = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpScript))

$shellCmd = @"
# 1. Create the cleanup PHP script
echo $b64Script | base64 -d > /app/moodle/local/cleanup_stale_locks.php
chmod 644 /app/moodle/local/cleanup_stale_locks.php
echo "Created /app/moodle/local/cleanup_stale_locks.php"

# 2. Verify the script works
php /app/moodle/local/cleanup_stale_locks.php 2>&1
echo "Script test: exit code=\$?"

# 3. Add cron job (every 5 minutes) if not already present
CRON_LINE="*/5 * * * * php /app/moodle/local/cleanup_stale_locks.php > /dev/null 2>&1"
if crontab -l 2>/dev/null | grep -q "cleanup_stale_locks"; then
    echo "Cron job already exists - updating"
    crontab -l 2>/dev/null | grep -v "cleanup_stale_locks" | { cat; echo "\$CRON_LINE"; } | crontab -
else
    echo "Adding new cron job"
    (crontab -l 2>/dev/null; echo "\$CRON_LINE") | crontab -
fi

# 4. Verify cron
echo "=== Current crontab ==="
crontab -l 2>/dev/null | grep -i "lock\|cleanup\|moodle"
echo "=== Done ==="
echo "EXIT=0"
"@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 90
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

