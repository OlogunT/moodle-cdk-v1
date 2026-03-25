# Fix moodle/course:view Prohibit on student role - change to Allow
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

$studentroleid = 5;
$sysctx = context_system::instance();

echo "=== Before fix ===\n";
$cap = $DB->get_record('role_capabilities', array(
    'roleid' => $studentroleid,
    'capability' => 'moodle/course:view',
    'contextid' => $sysctx->id
));
$perms = [-1=>'Prevent', 0=>'Not set', 1=>'Allow', -1000=>'Prohibit'];
echo "moodle/course:view: " . ($cap ? ($perms[$cap->permission] ?? $cap->permission) : 'NOT SET') . "\n";

echo "\n=== Fix: Set to Allow ===\n";
assign_capability('moodle/course:view', CAP_ALLOW, $studentroleid, $sysctx->id, true);
echo "Set moodle/course:view = Allow for student role (id=5)\n";

echo "\n=== Check for other problematic student capabilities ===\n";
$problemcaps = $DB->get_records_sql(
    "SELECT rc.id, rc.capability, rc.permission, rc.contextid
     FROM {role_capabilities} rc
     WHERE rc.roleid = ? AND rc.permission = -1000",
    array($studentroleid)
);
echo "Capabilities set to Prohibit for student role:\n";
foreach ($problemcaps as $p) {
    echo "  $p->capability (contextid=$p->contextid): " . ($perms[$p->permission] ?? $p->permission) . "\n";
}
if (empty($problemcaps)) echo "  None\n";

echo "\n=== After fix ===\n";
$cap2 = $DB->get_record('role_capabilities', array(
    'roleid' => $studentroleid,
    'capability' => 'moodle/course:view',
    'contextid' => $sysctx->id
));
echo "moodle/course:view: " . ($cap2 ? ($perms[$cap2->permission] ?? $cap2->permission) : 'NOT SET') . "\n";

echo "\n=== Purge caches ===\n";
purge_all_caches();
echo "Caches purged\n";

echo "\n=== Verify for student account ===\n";
$student = $DB->get_record('user', array('email' => 'connie.stanclik@gmail.com'));
if ($student) {
    $coursectx = context_course::instance(113);
    accesslib_clear_all_caches_for_unit_testing();
    $has = has_capability('moodle/course:view', $coursectx, $student->id);
    echo "Student moodle/course:view in course 113: " . ($has ? "YES - FIXED" : "STILL NO") . "\n";
    $hasread = has_capability('mod/book:read', $coursectx, $student->id);
    echo "Student mod/book:read in course 113: " . ($hasread ? "YES" : "NO") . "\n";
}

echo "\n=== Restart PHP-FPM ===\n";
exec('systemctl restart php-fpm 2>&1', $out, $ret);
echo implode("\n", $out) . "\n";
echo "PHP-FPM restart exit: $ret\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_view.php && php /tmp/fix_view.php 2>&1 && echo EXIT=0"

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

