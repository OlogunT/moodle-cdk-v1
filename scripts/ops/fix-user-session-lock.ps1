# Fix stuck session lock for specific user c.stanclik
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. Find user c.stanclik ===\n";
$user = $DB->get_record('user', array('username' => 'c.stanclik'));
if ($user) {
    echo "User ID: $user->id\n";
    echo "Name: $user->firstname $user->lastname\n";
    echo "Email: $user->email\n";
    echo "Last login: " . date('Y-m-d H:i:s', $user->lastlogin) . "\n";
    echo "Current login: " . date('Y-m-d H:i:s', $user->currentlogin) . "\n";
} else {
    echo "User NOT found\n";
    exit(1);
}

echo "\n=== 2. Find active sessions for this user ===\n";
$redis = new Redis();
$redis->connect("moo-mo-isf4hcml1bjy.cgt4zg.0001.cac1.cache.amazonaws.com", 6379);
$redis->select(0);

// Find all session keys
$allSessions = $redis->keys("mdl_sess_*");
echo "Total sessions in Redis: " . count($allSessions) . "\n";

// Find sessions belonging to this user
$userSessions = [];
foreach ($allSessions as $key) {
    if (strpos($key, 'lock') !== false) continue;
    $data = $redis->get($key);
    if ($data && strpos($data, strval($user->id)) !== false) {
        $userSessions[] = $key;
    }
}
echo "Sessions potentially for user {$user->id}: " . count($userSessions) . "\n";
foreach ($userSessions as $s) {
    echo "  $s\n";
}

echo "\n=== 3. Find ALL lock keys ===\n";
$lockKeys = $redis->keys("*lock*");
echo "Total lock keys: " . count($lockKeys) . "\n";
foreach ($lockKeys as $k) {
    $ttl = $redis->ttl($k);
    echo "  $k (TTL: {$ttl}s)\n";
}

echo "\n=== 4. Delete lock keys for this user's sessions ===\n";
$cleared = 0;
foreach ($userSessions as $sessKey) {
    // Extract session id from key
    $sessId = str_replace('mdl_sess_', '', $sessKey);
    $lockKey = "mdl_sess_lock:$sessId";
    if ($redis->exists($lockKey)) {
        echo "  Deleting lock: $lockKey\n";
        $redis->del($lockKey);
        $cleared++;
    }
}

// Also try other lock key patterns
$allLocks = $redis->keys("*lock*");
foreach ($allLocks as $lk) {
    echo "  Deleting remaining lock: $lk\n";
    $redis->del($lk);
    $cleared++;
}
echo "Cleared $cleared lock keys\n";

echo "\n=== 5. Delete stale sessions for this user ===\n";
foreach ($userSessions as $sessKey) {
    echo "  Deleting session: $sessKey\n";
    $redis->del($sessKey);
}
echo "Deleted " . count($userSessions) . " sessions for user\n";

echo "\n=== 6. Also check DB lock table ===\n";
$dblocks = $DB->get_records_sql("SELECT * FROM {lock_db} WHERE expires < ?", [time()]);
$expired = count($dblocks);
if ($expired > 0) {
    $DB->delete_records_select('lock_db', 'expires < ?', [time()]);
    echo "Cleared $expired expired DB locks\n";
} else {
    echo "No expired DB locks\n";
}

// Check for any locks held too long
$allDblocks = $DB->get_records('lock_db');
echo "Active DB locks: " . count($allDblocks) . "\n";
foreach ($allDblocks as $dl) {
    echo "  resource=$dl->resourcekey owner=$dl->owner expires=" . date('H:i:s', $dl->expires) . "\n";
}

echo "\n=== 7. Kill stuck PHP-FPM workers ===\n";
echo "Restarting PHP-FPM to clear any stuck processes...\n";

echo "\nDone - user c.stanclik should clear browser cookies and try again\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_user_lock.php && php /tmp/fix_user_lock.php 2>&1 && systemctl restart php-fpm 2>&1 && echo 'PHP-FPM restarted' && echo EXIT=0"

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

