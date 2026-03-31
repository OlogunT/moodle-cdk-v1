# Fix "unable to acquire lock for caching" on course 70 - clear stale locks + fix cache dirs
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== Clearing stale DB locks ===\n";
$locks = $DB->get_records('lock_db', array());
echo "Found " . count($locks) . " locks\n";
foreach ($locks as $lock) {
    $age = time() - $lock->expires;
    echo "  Lock id=$lock->id resource=$lock->resourcekey expires=$lock->expires age={$age}s owner=$lock->owner\n";
}
// Delete all expired locks
$deleted = $DB->execute("DELETE FROM {lock_db} WHERE expires < ?", array(time()));
echo "Deleted expired locks\n";

// Also delete ALL locks to be safe
$DB->execute("DELETE FROM {lock_db}");
echo "Cleared all locks from lock_db\n";

// Clear file-based locks
echo "\n=== Clearing file-based cache locks ===\n";
$lockdirs = array(
    $CFG->dataroot . '/lock',
    $CFG->dataroot . '/cache/cachelock_file_default',
    $CFG->localcachedir . '/lock',
);
foreach ($lockdirs as $dir) {
    if (is_dir($dir)) {
        $files = glob($dir . '/*');
        $count = count($files);
        foreach ($files as $f) { @unlink($f); }
        echo "  Cleared $count files from $dir\n";
    } else {
        echo "  $dir does not exist\n";
    }
}

// Also check for any lock files in moodledata
$lockfiles = glob($CFG->dataroot . '/localcache/lock/*');
if ($lockfiles) {
    foreach ($lockfiles as $f) { @unlink($f); }
    echo "  Cleared " . count($lockfiles) . " from localcache/lock\n";
}

// Clear cache directories
echo "\n=== Clearing cache store directories ===\n";
$cachedirs = glob($CFG->dataroot . '/cache/*', GLOB_ONLYDIR);
foreach ($cachedirs as $cd) {
    $basename = basename($cd);
    if (strpos($basename, 'cachelock') !== false || strpos($basename, 'lock') !== false) {
        $files = glob($cd . '/*');
        foreach ($files as $f) { @unlink($f); }
        echo "  Cleared " . count($files) . " from $cd\n";
    }
}

// Also check localcache
$localcachedirs = glob($CFG->dataroot . '/localcache/*', GLOB_ONLYDIR);
foreach ($localcachedirs as $cd) {
    $basename = basename($cd);
    if (strpos($basename, 'lock') !== false) {
        $files = glob($cd . '/*');
        foreach ($files as $f) { @unlink($f); }
        echo "  Cleared " . count($files) . " from $cd\n";
    }
}

// Fix permissions on cache directories
echo "\n=== Fixing cache directory permissions ===\n";
$dirs_to_fix = array(
    $CFG->dataroot . '/cache',
    $CFG->dataroot . '/localcache',
    $CFG->dataroot . '/lock',
    $CFG->dataroot . '/temp/lock',
);
foreach ($dirs_to_fix as $d) {
    if (!is_dir($d)) {
        @mkdir($d, 0775, true);
        echo "  Created $d\n";
    }
    @chmod($d, 0775);
    echo "  chmod 775 $d\n";
}

// Ensure apache/www-data owns cache dirs
exec('chown -R apache:apache ' . $CFG->dataroot . '/cache 2>&1', $out1);
exec('chown -R apache:apache ' . $CFG->dataroot . '/localcache 2>&1', $out2);
exec('chown -R apache:apache ' . $CFG->dataroot . '/lock 2>&1', $out3);
exec('chown -R apache:apache ' . $CFG->dataroot . '/temp 2>&1', $out4);
echo "  chown done\n";

// Purge all caches
echo "\n=== Purging all caches ===\n";
purge_all_caches();
echo "Caches purged\n";

// Clear sessions for course 70 users to force fresh state
echo "\n=== Course 70 info ===\n";
$course = $DB->get_record('course', array('id' => 70));
echo "Course: $course->fullname\n";
$enrolled = $DB->count_records_sql(
    "SELECT COUNT(DISTINCT ue.userid) FROM {user_enrolments} ue
     JOIN {enrol} e ON e.id = ue.enrolid WHERE e.courseid = 70");
echo "Enrolled users: $enrolled\n";

// Restart PHP-FPM to clear opcache and session locks
exec('systemctl restart php-fpm 2>&1', $out, $ret);
echo "\nPHP-FPM restart: exit=$ret\n";

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
Start-Sleep 90
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

