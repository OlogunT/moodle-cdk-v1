# Fix cache lock: create lock dir + switch to DB lock factory
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. Create lock directory ===\n";
$lockdir = $CFG->dataroot . '/lock';
if (!is_dir($lockdir)) {
    mkdir($lockdir, 0777, true);
    echo "Created: $lockdir\n";
} else {
    echo "Already exists: $lockdir\n";
}
chmod($lockdir, 0777);
echo "Permissions set\n";

echo "\n=== 2. Test lock directory writability ===\n";
$testfile = $lockdir . '/test_' . time();
if (file_put_contents($testfile, 'test')) {
    echo "Lock dir is writable\n";
    unlink($testfile);
} else {
    echo "ERROR: Lock dir NOT writable\n";
}

echo "\n=== 3. Check current config.php for lock_factory ===\n";
$config = file_get_contents('/app/moodle/config.php');
if (strpos($config, 'lock_factory') !== false) {
    echo "lock_factory already configured\n";
} else {
    echo "No lock_factory in config.php - adding DB lock factory\n";
    $insertion = "\n// Use database lock factory instead of file (NFS is too slow for file locks)\n\$CFG->lock_factory = '\\\\core\\\\lock\\\\db_record_lock_factory';\n";
    $config = str_replace('require_once(__DIR__', $insertion . 'require_once(__DIR__', $config);
    file_put_contents('/app/moodle/config.php', $config);
    echo "Added db_record_lock_factory to config.php\n";
}

echo "\n=== 4. Verify config.php ===\n";
$newconfig = file_get_contents('/app/moodle/config.php');
preg_match_all('/lock_factory.*/', $newconfig, $matches);
foreach ($matches[0] as $m) { echo "  $m\n"; }

echo "\n=== 5. Purge caches ===\n";
purge_all_caches();
echo "Caches purged\n";

echo "\n=== 6. Restart PHP-FPM ===\n";
echo "Done - restart PHP-FPM separately\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_cache2.php && php /tmp/fix_cache2.php 2>&1 && systemctl restart php-fpm 2>&1 && echo 'PHP-FPM restarted' && echo EXIT=0"

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

