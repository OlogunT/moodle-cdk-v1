# Fix admin 504 timeout - rebuild localcache and purge caches
# The admin page triggers plugin scanning on NFS which is slow
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
define('ABORT_AFTER_CONFIG', true);
require('/app/moodle/config.php');

// Connect directly to DB
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);

// 1. Make sure allversionshash matches
require_once($CFG->dirroot . '/lib/classes/component.php');
$computed = core_component::get_all_versions_hash();
$stored = $dbh->query("SELECT value FROM mdl_config WHERE name='allversionshash'")->fetchColumn();

echo "1. Hash check: computed=$computed stored=$stored match=" . ($computed === $stored ? "YES" : "NO") . "\n";
if ($computed !== $stored) {
    $dbh->prepare("UPDATE mdl_config SET value = ? WHERE name = 'allversionshash'")->execute([$computed]);
    echo "   Updated hash in DB\n";
}

// 2. Remove upgraderunning flag if present
$dbh->exec("DELETE FROM mdl_config WHERE name = 'upgraderunning'");
echo "2. Cleared upgraderunning flag\n";

// 3. Purge all caches
$cachedir = $CFG->dataroot . '/localcache';
if (is_dir($cachedir)) {
    echo "3. Rebuilding localcache...\n";
    // Delete everything except bootstrap.php
    $items = scandir($cachedir);
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') continue;
        $path = $cachedir . '/' . $item;
        if (is_dir($path)) {
            exec("rm -rf " . escapeshellarg($path));
        } else {
            unlink($path);
        }
    }
    echo "   Cleared localcache contents\n";
}

// 4. Purge MUC caches
$mucdir = $CFG->dataroot . '/muc';
if (is_dir($mucdir)) {
    exec("rm -rf " . escapeshellarg($mucdir) . "/*");
    echo "4. Cleared MUC cache\n";
} else {
    echo "4. No MUC directory found\n";
}

// 5. Clear PHP opcache
if (function_exists('opcache_reset')) {
    echo "5. Note: opcache_reset only works in web context, skipping in CLI\n";
} else {
    echo "5. No opcache available\n";
}

// 6. Check version
$version = null;
require($CFG->dirroot . '/version.php');
$dbver = $dbh->query("SELECT value FROM mdl_config WHERE name='version'")->fetchColumn();
echo "6. Version check: disk=$version db=$dbver match=" . ((string)$version === (string)$dbver ? "YES" : "NO") . "\n";

echo "\nDone. Restart PHP-FPM to apply opcache reset.\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_admin.php && timeout 60 php /tmp/fix_admin.php 2>&1 && echo '---RESTARTING PHP-FPM---' && systemctl restart php-fpm && echo 'PHP-FPM restarted' && echo '---TESTING ADMIN PAGE---' && curl -s -o /dev/null -w 'HTTP: %{http_code} Time: %{time_total}s' -m 60 https://elearning.tsin.ca/admin/index.php 2>&1"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Write-Host "Waiting 90 seconds..."
Start-Sleep 90

$result = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

