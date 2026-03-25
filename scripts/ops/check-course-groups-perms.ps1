# Check course setup, groups, and user permissions for the affected course and users
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

$students = array('connie.stanclik@gmail.com');
$admins = array('c.stanclik@tsin.ca', 'tsin-admin');

echo "=== 1. Course 113 setup ===\n";
$course = $DB->get_record('course', array('id' => 113));
echo "Name: $course->fullname\n";
echo "Shortname: $course->shortname\n";
echo "Visible: $course->visible\n";
echo "Format: $course->format\n";
echo "Groupmode: $course->groupmode\n";
echo "Groupmodeforce: $course->groupmodeforce\n";
$groupmodes = [0=>'No groups', 1=>'Separate groups', 2=>'Visible groups'];
echo "Groupmode meaning: " . ($groupmodes[$course->groupmode] ?? 'unknown') . "\n";
echo "Groupmodeforce meaning: " . ($course->groupmodeforce ? 'YES forced' : 'NO not forced') . "\n";
echo "startdate: " . date('Y-m-d', $course->startdate) . "\n";
echo "enddate: " . ($course->enddate ? date('Y-m-d', $course->enddate) : 'none') . "\n";

echo "\n=== 2. Groups in course 113 ===\n";
$groups = $DB->get_records('groups', array('courseid' => 113));
if (empty($groups)) {
    echo "No groups defined\n";
} else {
    foreach ($groups as $g) {
        $membercount = $DB->count_records('groups_members', array('groupid' => $g->id));
        echo "Group [$g->id]: $g->name ($membercount members)\n";
    }
}

echo "\n=== 3. Groupings in course 113 ===\n";
$groupings = $DB->get_records('groupings', array('courseid' => 113));
if (empty($groupings)) {
    echo "No groupings defined\n";
} else {
    foreach ($groupings as $gi) {
        echo "Grouping [$gi->id]: $gi->name\n";
        $gg = $DB->get_records('groupings_groups', array('groupingid' => $gi->id));
        foreach ($gg as $link) {
            $gname = $DB->get_field('groups', 'name', array('id' => $link->groupid));
            echo "  -> Group: $gname (id=$link->groupid)\n";
        }
    }
}

echo "\n=== 4. CM 3852 (book) group/restriction settings ===\n";
$cm = $DB->get_record('course_modules', array('id' => 3852));
if ($cm) {
    echo "Visible: $cm->visible\n";
    echo "Visibleoncoursepage: $cm->visibleoncoursepage\n";
    echo "Groupmode: $cm->groupmode (" . ($groupmodes[$cm->groupmode] ?? 'unknown') . ")\n";
    echo "Groupingid: $cm->groupingid\n";
    echo "Availability: " . ($cm->availability ? $cm->availability : 'none') . "\n";
    if ($cm->groupingid > 0) {
        $gi = $DB->get_record('groupings', array('id' => $cm->groupingid));
        echo "Grouping name: " . ($gi ? $gi->name : 'NOT FOUND') . "\n";
    }
}

echo "\n=== 5. Student accounts - enrolment, groups, roles ===\n";
foreach ($students as $email) {
    $u = $DB->get_record('user', array('email' => $email));
    if (!$u) { $u = $DB->get_record('user', array('username' => $email)); }
    if (!$u) { echo "User $email NOT FOUND\n"; continue; }
    echo "\n--- $u->username (id=$u->id, email=$u->email) ---\n";

    // Enrolment
    $enrols = $DB->get_records_sql(
        "SELECT ue.id, ue.status, ue.timestart, ue.timeend, e.enrol, e.status as estatus
         FROM {user_enrolments} ue JOIN {enrol} e ON e.id = ue.enrolid
         WHERE ue.userid = ? AND e.courseid = ?", array($u->id, 113));
    if (empty($enrols)) { echo "  NOT enrolled in course 113\n"; }
    foreach ($enrols as $e) {
        $ust = $e->status == 0 ? 'active' : 'suspended';
        $est = $e->estatus == 0 ? 'active' : 'disabled';
        echo "  Enrolment: $e->enrol user=$ust enrol=$est";
        echo " start=" . ($e->timestart ? date('Y-m-d', $e->timestart) : 'none');
        echo " end=" . ($e->timeend ? date('Y-m-d', $e->timeend) : 'none') . "\n";
    }

    // Groups
    $ugroups = $DB->get_records_sql(
        "SELECT g.id, g.name FROM {groups} g
         JOIN {groups_members} gm ON gm.groupid = g.id
         WHERE gm.userid = ? AND g.courseid = ?", array($u->id, 113));
    if (empty($ugroups)) { echo "  NOT in any group\n"; }
    foreach ($ugroups as $ug) { echo "  Group: $ug->name (id=$ug->id)\n"; }

    // Role in course
    $coursectx = context_course::instance(113);
    $roles = get_user_roles($coursectx, $u->id);
    foreach ($roles as $r) { echo "  Course role: $r->shortname\n"; }
    if (empty($roles)) { echo "  No course-level role\n"; }

    // Key capabilities
    $caps = array('moodle/course:view','mod/book:read','moodle/course:viewhiddencourses',
                  'moodle/course:viewhiddensections','moodle/course:viewhiddenactivities');
    foreach ($caps as $c) {
        echo "  $c: " . (has_capability($c, $coursectx, $u->id) ? 'YES' : 'NO') . "\n";
    }
}

echo "\n=== 6. Admin/manager accounts - same checks ===\n";
foreach ($admins as $identifier) {
    $u = $DB->get_record('user', array('email' => $identifier));
    if (!$u) { $u = $DB->get_record('user', array('username' => $identifier)); }
    if (!$u) { echo "User $identifier NOT FOUND\n"; continue; }
    echo "\n--- $u->username (id=$u->id) ---\n";
    echo "  Site admin: " . (is_siteadmin($u->id) ? 'YES' : 'NO') . "\n";

    $enrols = $DB->get_records_sql(
        "SELECT ue.status, e.enrol FROM {user_enrolments} ue
         JOIN {enrol} e ON e.id = ue.enrolid
         WHERE ue.userid = ? AND e.courseid = ?", array($u->id, 113));
    if (empty($enrols)) { echo "  NOT enrolled (accesses via admin)\n"; }
    foreach ($enrols as $e) { echo "  Enrolment: $e->enrol status=$e->status\n"; }

    $ugroups = $DB->get_records_sql(
        "SELECT g.id, g.name FROM {groups} g
         JOIN {groups_members} gm ON gm.groupid = g.id
         WHERE gm.userid = ? AND g.courseid = ?", array($u->id, 113));
    if (empty($ugroups)) { echo "  NOT in any group\n"; }
    foreach ($ugroups as $ug) { echo "  Group: $ug->name (id=$ug->id)\n"; }
}

echo "\n=== 7. All activities with availability restrictions in course 113 ===\n";
$restricted = $DB->get_records_sql(
    "SELECT id, module, instance, visible, groupmode, groupingid, availability
     FROM {course_modules} WHERE course = 113 AND availability IS NOT NULL AND availability != ''");
echo count($restricted) . " activities have restrictions\n";
foreach (array_slice($restricted, 0, 10) as $r) {
    $mod = $DB->get_field('modules', 'name', array('id' => $r->module));
    echo "  CM $r->id ($mod): vis=$r->visible grpmode=$r->groupmode grping=$r->groupingid\n";
    echo "    availability: $r->availability\n";
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/check_groups.php && php /tmp/check_groups.php 2>&1 && echo EXIT=0"

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

