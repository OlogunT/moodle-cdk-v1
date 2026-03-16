# Fix Moodle caching lock issue - switch lock factory and clear cache locks
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. Current lock config ===\n";
$lockcfg = $DB->get_records('config_plugins', array('plugin' => 'cachelock_file'));
foreach ($lockcfg as $c) { echo "  $c->name = $c->value\n"; }

echo "\n=== 2. Check lock directory ===\n";
$lockdir = $CFG->dataroot . '/lock';
echo "Lock dir: $lockdir\n";
echo "Exists: " . (is_dir($lockdir) ? "YES" : "NO") . "\n";
if (is_dir($lockdir)) {
    $files = glob("$lockdir/*");
    echo "Lock files: " . count($files) . "\n";
    foreach (array_slice($files, 0, 10) as $f) { echo "  $f\n"; }
}

echo "\n=== 3. Check moodledata/localcache ===\n";
$lcdir = $CFG->localcachedir ?? $CFG->dataroot . '/localcache';
echo "localcachedir: $lcdir\n";
echo "Exists: " . (is_dir($lcdir) ? "YES" : "NO") . "\n";

echo "\n=== 4. Clear stale lock files ===\n";
if (is_dir($lockdir)) {
    $files = glob("$lockdir/*");
    $cleared = 0;
    foreach ($files as $f) {
        if (is_file($f)) {
            $age = time() - filemtime($f);
            if ($age > 60) {
                unlink($f);
                $cleared++;
            }
        }
    }
    echo "Cleared $cleared stale lock files\n";
}

echo "\n=== 5. Check /tmp for lock files ===\n";
$tmpfiles = glob("/tmp/core_lock_*");
echo "Temp lock files: " . count($tmpfiles) . "\n";
foreach ($tmpfiles as $f) { unlink($f); }
echo "Cleared temp lock files\n";

echo "\n=== 6. Check config.php for lock settings ===\n";
$configContent = file_get_contents('/app/moodle/config.php');
if (preg_match_all('/lock/i', $configContent, $m)) {
    echo "Found " . count($m[0]) . " lock references in config.php\n";
}

echo "\n=== 7. Purge all caches ===\n";
purge_all_caches();
echo "Caches purged\n";

echo "\n=== 8. Check cache config ===\n";
$cachefile = $CFG->dataroot . '/muc/config.php';
echo "MUC config exists: " . (file_exists($cachefile) ? "YES" : "NO") . "\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_cache_lock.php && php /tmp/fix_cache_lock.php 2>&1 && echo EXIT=0"

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

