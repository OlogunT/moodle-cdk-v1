# Check roles and permissions for user c.stanclik
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

$user = $DB->get_record('user', array('username' => 'c.stanclik'));
if (!$user) { echo "User not found\n"; exit(1); }

echo "=== User Info ===\n";
echo "ID: $user->id\n";
echo "Username: $user->username\n";
echo "Name: $user->firstname $user->lastname\n";
echo "Email: $user->email\n";
echo "Auth: $user->auth\n";
echo "Suspended: $user->suspended\n";
echo "Confirmed: $user->confirmed\n";
echo "Last login: " . ($user->lastlogin ? date('Y-m-d H:i:s', $user->lastlogin) : 'never') . "\n";

echo "\n=== System-level Role Assignments ===\n";
$sysctx = context_system::instance();
$sysroles = get_user_roles($sysctx, $user->id);
if (empty($sysroles)) {
    echo "No system-level roles\n";
} else {
    foreach ($sysroles as $r) {
        echo "  Role: $r->shortname (id=$r->roleid)\n";
    }
}

echo "\n=== Site Admin Check ===\n";
$admins = explode(',', $CFG->siteadmins);
echo "Is site admin: " . (in_array($user->id, $admins) ? "YES" : "NO") . "\n";

echo "\n=== Course Enrolments & Roles ===\n";
$sql = "SELECT c.id as courseid, c.shortname, c.fullname, r.shortname as rolename, r.id as roleid, ue.status
        FROM {user_enrolments} ue
        JOIN {enrol} e ON e.id = ue.enrolid
        JOIN {course} c ON c.id = e.courseid
        JOIN {role_assignments} ra ON ra.userid = ue.userid
        JOIN {context} ctx ON ctx.id = ra.contextid AND ctx.contextlevel = 50 AND ctx.instanceid = c.id
        JOIN {role} r ON r.id = ra.roleid
        WHERE ue.userid = ?
        ORDER BY c.shortname";
$enrolments = $DB->get_records_sql($sql, [$user->id]);

if (empty($enrolments)) {
    echo "No course enrolments found\n";
} else {
    $currentCourse = '';
    foreach ($enrolments as $e) {
        if ($e->courseid != $currentCourse) {
            $status = $e->status == 0 ? 'active' : 'suspended';
            echo "\n  Course [$e->courseid]: $e->fullname ($e->shortname) - $status\n";
            $currentCourse = $e->courseid;
        }
        echo "    -> Role: $e->rolename (id=$e->roleid)\n";
    }
}

echo "\n=== Category-level Roles ===\n";
$sql2 = "SELECT ra.id, r.shortname as rolename, cc.name as catname, cc.id as catid
         FROM {role_assignments} ra
         JOIN {role} r ON r.id = ra.roleid
         JOIN {context} ctx ON ctx.id = ra.contextid AND ctx.contextlevel = 40
         JOIN {course_categories} cc ON cc.id = ctx.instanceid
         WHERE ra.userid = ?";
$catroles = $DB->get_records_sql($sql2, [$user->id]);
if (empty($catroles)) {
    echo "No category-level roles\n";
} else {
    foreach ($catroles as $cr) {
        echo "  Category [$cr->catid]: $cr->catname -> Role: $cr->rolename\n";
    }
}

echo "\n=== All Role Assignments (any context) ===\n";
$sql3 = "SELECT ra.id, r.shortname as rolename, ctx.contextlevel, ctx.instanceid
         FROM {role_assignments} ra
         JOIN {role} r ON r.id = ra.roleid
         JOIN {context} ctx ON ctx.id = ra.contextid
         WHERE ra.userid = ?
         ORDER BY ctx.contextlevel";
$allroles = $DB->get_records_sql($sql3, [$user->id]);
$levels = [10=>'System',30=>'User',40=>'Category',50=>'Course',70=>'Module',80=>'Block'];
foreach ($allroles as $ar) {
    $lvl = $levels[$ar->contextlevel] ?? "Level-$ar->contextlevel";
    echo "  $lvl (instance=$ar->instanceid): $ar->rolename\n";
}
echo "\nTotal role assignments: " . count($allroles) . "\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/check_roles.php && php /tmp/check_roles.php 2>&1 && echo EXIT=0"

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
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

