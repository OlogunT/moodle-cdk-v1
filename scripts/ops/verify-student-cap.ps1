# Verify the student capability fix and restart PHP-FPM
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

$studentroleid = 5;
$sysctx = context_system::instance();
$perms = [-1=>'Prevent', 0=>'Not set', 1=>'Allow', -1000=>'Prohibit'];

echo "=== Student role moodle/course:view ===\n";
$cap = $DB->get_record('role_capabilities', array(
    'roleid' => $studentroleid,
    'capability' => 'moodle/course:view',
    'contextid' => $sysctx->id
));
echo "moodle/course:view: " . ($cap ? ($perms[$cap->permission] ?? $cap->permission) : 'NOT SET') . "\n";

echo "\n=== Verify student access ===\n";
$student = $DB->get_record('user', array('email' => 'connie.stanclik@gmail.com'));
if ($student) {
    $coursectx = context_course::instance(113);
    $has = has_capability('moodle/course:view', $coursectx, $student->id);
    echo "Student moodle/course:view in course 113: " . ($has ? "YES - FIXED" : "STILL NO") . "\n";
    $hasread = has_capability('mod/book:read', $coursectx, $student->id);
    echo "Student mod/book:read in course 113: " . ($hasread ? "YES" : "NO") . "\n";
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/verify_cap.php && php /tmp/verify_cap.php 2>&1; systemctl restart php-fpm 2>&1; echo PHP-FPM restarted; echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 60
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

