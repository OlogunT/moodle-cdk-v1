# Diagnose and fix moodle/course:view capability for student role
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. Check student role definition ===\n";
$studentrole = $DB->get_record('role', array('shortname' => 'student'));
echo "Student role ID: $studentrole->id\n";

// Check the capability at role definition level
$cap = $DB->get_record('role_capabilities', array(
    'roleid' => $studentrole->id,
    'capability' => 'moodle/course:view',
    'contextid' => 1  // system context
));
if ($cap) {
    $perms = [-1=>'Prevent', 0=>'Not set', 1=>'Allow', -1000=>'Prohibit'];
    echo "moodle/course:view permission: " . ($perms[$cap->permission] ?? $cap->permission) . "\n";
} else {
    echo "moodle/course:view: NOT SET in role definition\n";
}

echo "\n=== 2. Check all overrides for moodle/course:view on student role ===\n";
$overrides = $DB->get_records_sql(
    "SELECT rc.*, ctx.contextlevel, ctx.instanceid
     FROM {role_capabilities} rc
     JOIN {context} ctx ON ctx.id = rc.contextid
     WHERE rc.roleid = ? AND rc.capability = 'moodle/course:view'",
    [$studentrole->id]
);
$perms = [-1=>'Prevent', 0=>'Not set', 1=>'Allow', -1000=>'Prohibit'];
$levels = [10=>'System',30=>'User',40=>'Category',50=>'Course',70=>'Module',80=>'Block'];
foreach ($overrides as $o) {
    $lvl = $levels[$o->contextlevel] ?? "Level-$o->contextlevel";
    echo "  $lvl (instance=$o->instanceid, ctx=$o->contextid): " . ($perms[$o->permission] ?? $o->permission) . "\n";
}
if (empty($overrides)) echo "  No overrides found\n";

echo "\n=== 3. Check ALL capabilities for student role with Prevent or Prohibit ===\n";
$prevents = $DB->get_records_sql(
    "SELECT rc.capability, rc.permission, ctx.contextlevel
     FROM {role_capabilities} rc
     JOIN {context} ctx ON ctx.id = rc.contextid
     WHERE rc.roleid = ? AND rc.permission < 0
     ORDER BY rc.capability",
    [$studentrole->id]
);
foreach ($prevents as $p) {
    $lvl = $levels[$p->contextlevel] ?? "Level-$p->contextlevel";
    echo "  $p->capability: " . ($perms[$p->permission] ?? $p->permission) . " at $lvl\n";
}

echo "\n=== 4. Check authenticated user role for moodle/course:view ===\n";
$authrole = $DB->get_record('role', array('shortname' => 'user'));
if ($authrole) {
    $authcap = $DB->get_record('role_capabilities', array(
        'roleid' => $authrole->id,
        'capability' => 'moodle/course:view',
        'contextid' => 1
    ));
    if ($authcap) {
        echo "Authenticated user moodle/course:view: " . ($perms[$authcap->permission] ?? $authcap->permission) . "\n";
    } else {
        echo "Authenticated user: NOT SET\n";
    }
}

echo "\n=== 5. Check default role for course ===\n";
echo "defaultuserroleid: " . ($CFG->defaultuserroleid ?? 'not set') . "\n";
$defrole = $DB->get_record('role', array('id' => $CFG->defaultuserroleid));
if ($defrole) echo "Default role: $defrole->shortname\n";

echo "\n=== 6. Check guest access for course 113 ===\n";
$guest = $DB->get_record('enrol', array('courseid' => 113, 'enrol' => 'guest'));
if ($guest) {
    echo "Guest enrol status: " . ($guest->status == 0 ? 'enabled' : 'disabled') . "\n";
} else {
    echo "No guest enrolment\n";
}

echo "\n=== 7. Check if student role has moodle/course:view in any archetype ===\n";
echo "Student archetype: $studentrole->archetype\n";

echo "\n=== 8. Fix: Ensure student role has moodle/course:view = Allow ===\n";
$sysctx = context_system::instance();
// Check current
$existing = $DB->get_record('role_capabilities', array(
    'roleid' => $studentrole->id,
    'capability' => 'moodle/course:view',
    'contextid' => $sysctx->id
));
if (!$existing) {
    // Add the capability
    assign_capability('moodle/course:view', CAP_ALLOW, $studentrole->id, $sysctx->id, true);
    echo "FIXED: Added moodle/course:view = Allow for student role at system level\n";
} elseif ($existing->permission != CAP_ALLOW) {
    assign_capability('moodle/course:view', CAP_ALLOW, $studentrole->id, $sysctx->id, true);
    echo "FIXED: Changed moodle/course:view to Allow for student role\n";
} else {
    echo "Already set to Allow - issue might be at override level\n";
    // Remove any Prevent/Prohibit overrides
    $bad = $DB->get_records_sql(
        "SELECT rc.id, rc.contextid, ctx.contextlevel, ctx.instanceid
         FROM {role_capabilities} rc
         JOIN {context} ctx ON ctx.id = rc.contextid
         WHERE rc.roleid = ? AND rc.capability = 'moodle/course:view' AND rc.permission < 0",
        [$studentrole->id]
    );
    foreach ($bad as $b) {
        $DB->delete_records('role_capabilities', array('id' => $b->id));
        $lvl = $levels[$b->contextlevel] ?? "Level-$b->contextlevel";
        echo "  Removed Prevent/Prohibit override at $lvl (instance=$b->instanceid)\n";
    }
}

echo "\n=== 9. Purge caches ===\n";
purge_all_caches();
echo "Caches purged\n";

echo "\n=== 10. Verify fix ===\n";
$student = $DB->get_record('user', array('email' => 'connie.stanclik@gmail.com'));
$coursectx = context_course::instance(113);
accesslib_clear_all_caches_for_unit_testing();
$has = has_capability('moodle/course:view', $coursectx, $student->id);
echo "Student moodle/course:view in course 113: " . ($has ? "YES" : "STILL NO") . "\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_cap.php && php /tmp/fix_cap.php 2>&1 && echo EXIT=0"

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

