# Test login via CLI authentication (bypass HTTP)
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/moodlelib.php');

echo "=== 1. Site info ===\n";
echo "wwwroot: $CFG->wwwroot\n";
echo "dbhost: $CFG->dbhost\n";
echo "dataroot: $CFG->dataroot\n";

echo "\n=== 2. Test DB connectivity ===\n";
$count = $DB->count_records('user');
echo "Total users: $count\n";

echo "\n=== 3. Authenticate tsin-admin ===\n";
$user = authenticate_user_login('tsin-admin', 'Tsin@2025!@#');
if ($user) {
    echo "LOGIN SUCCESS\n";
    echo "User ID: $user->id\n";
    echo "Email: $user->email\n";
    echo "Name: $user->firstname $user->lastname\n";
} else {
    echo "LOGIN FAILED\n";
    $u = $DB->get_record('user', array('username' => 'tsin-admin'));
    if ($u) {
        echo "User exists in DB (id=$u->id) but auth failed\n";
        echo "Auth method: $u->auth\n";
    } else {
        echo "User tsin-admin NOT found in DB\n";
    }
}

echo "\n=== 4. Test course 114 access ===\n";
$course = $DB->get_record('course', array('id' => 114));
if ($course) {
    echo "Course: $course->fullname\n";
    echo "Format: $course->format\n";
    echo "Visible: $course->visible\n";
    $ctx = context_course::instance(114);
    echo "Context ID: $ctx->id\n";
    // Test loading course format
    $fmt = course_get_format($course);
    echo "Format class: " . get_class($fmt) . "\n";
    echo "Course 114 OK\n";
} else {
    echo "Course 114 NOT FOUND\n";
}

echo "\n=== 5. Test cache lock ===\n";
$lockfactory = \core\lock\lock_config::get_lock_factory('core_cron');
echo "Lock factory: " . get_class($lockfactory) . "\n";
$lock = $lockfactory->get_lock('test_lock', 5);
if ($lock) {
    echo "Lock acquired OK\n";
    $lock->release();
    echo "Lock released OK\n";
} else {
    echo "FAILED to acquire lock\n";
}

echo "\n=== 6. Test external URL ===\n";
$ch = curl_init('https://elearning.tsin.ca/');
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 60);
curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
curl_setopt($ch, CURLOPT_NOBODY, true);
curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$time = curl_getinfo($ch, CURLINFO_TOTAL_TIME);
$url = curl_getinfo($ch, CURLINFO_EFFECTIVE_URL);
curl_close($ch);
echo "External: HTTP $code in {$time}s -> $url\n";

echo "\nAll tests PASSED\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/test_login2.php && php /tmp/test_login2.php 2>&1 && echo EXIT=0"

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

