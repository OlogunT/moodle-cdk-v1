# Diagnose why images in pluginfile.php are not loading for student accounts
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

echo "=== 1. Student account info ===\n";
$student = $DB->get_record('user', array('email' => 'connie.stanclik@gmail.com'));
if (!$student) { echo "Student not found by email\n"; exit(1); }
echo "ID: $student->id\n";
echo "Username: $student->username\n";
echo "Name: $student->firstname $student->lastname\n";
echo "Suspended: $student->suspended\n";
echo "Confirmed: $student->confirmed\n";

echo "\n=== 2. Course module 3852 info ===\n";
$cm = $DB->get_record('course_modules', array('id' => 3852));
if (!$cm) { echo "CM 3852 not found\n"; } else {
    echo "Course ID: $cm->course\n";
    echo "Module: $cm->module\n";
    echo "Instance: $cm->instance\n";
    echo "Visible: $cm->visible\n";
    $course = $DB->get_record('course', array('id' => $cm->course));
    echo "Course: $course->fullname\n";
    echo "Course visible: $course->visible\n";
}

echo "\n=== 3. Student enrolment in course ===\n";
$enrolments = $DB->get_records_sql(
    "SELECT ue.*, e.enrol, e.status as enrolstatus
     FROM {user_enrolments} ue
     JOIN {enrol} e ON e.id = ue.enrolid
     WHERE ue.userid = ? AND e.courseid = ?",
    [$student->id, $cm->course]
);
if (empty($enrolments)) {
    echo "NOT ENROLLED in course $cm->course\n";
} else {
    foreach ($enrolments as $ue) {
        $uestatus = $ue->status == 0 ? 'active' : 'suspended';
        $estatus = $ue->enrolstatus == 0 ? 'active' : 'disabled';
        echo "Enrolment: method=$ue->enrol user_status=$uestatus enrol_status=$estatus\n";
        echo "  timestart=" . ($ue->timestart ? date('Y-m-d', $ue->timestart) : 'none') . "\n";
        echo "  timeend=" . ($ue->timeend ? date('Y-m-d', $ue->timeend) : 'none') . "\n";
    }
}

echo "\n=== 4. Student roles in this course ===\n";
$ctx = context_module::instance(3852);
$coursectx = context_course::instance($cm->course);
$roles = get_user_roles($coursectx, $student->id);
foreach ($roles as $r) { echo "  Role: $r->shortname\n"; }
if (empty($roles)) echo "  No roles in course context\n";

echo "\n=== 5. Check the specific file ===\n";
$file = $DB->get_record_sql(
    "SELECT * FROM {files}
     WHERE component = 'mod_book' AND filearea = 'chapter'
     AND contextid = ? AND filename LIKE '%Curricular%Advisory%'",
    [$ctx->id]
);
if ($file) {
    echo "File found: $file->filename\n";
    echo "  contextid: $file->contextid\n";
    echo "  itemid: $file->itemid\n";
    echo "  filesize: $file->filesize\n";
    echo "  mimetype: $file->mimetype\n";
} else {
    echo "File not found in context $ctx->id\n";
    // Try broader search
    $files = $DB->get_records_sql(
        "SELECT * FROM {files} WHERE filename LIKE '%Curricular%Advisory%' AND filename != '.'",
        []
    );
    echo "Broader search found " . count($files) . " files\n";
    foreach ($files as $f) {
        echo "  ctx=$f->contextid comp=$f->component area=$f->filearea name=$f->filename\n";
    }
}

echo "\n=== 6. Check capabilities ===\n";
$caps = ['mod/book:read', 'mod/book:viewhiddenchapters', 'moodle/course:view'];
foreach ($caps as $cap) {
    $has = has_capability($cap, $coursectx, $student->id);
    echo "  $cap: " . ($has ? "YES" : "NO") . "\n";
}

echo "\n=== 7. Check forcelogin and other settings ===\n";
echo "forcelogin: " . ($CFG->forcelogin ?? 'not set') . "\n";
echo "forceloginforprofileimage: " . ($CFG->forceloginforprofileimage ?? 'not set') . "\n";
echo "slasharguments: " . ($CFG->slasharguments ?? 'not set') . "\n";

echo "\n=== 8. Check session/auth issues ===\n";
echo "wwwroot: $CFG->wwwroot\n";
echo "cookiesecure: " . ($CFG->cookiesecure ?? 'not set') . "\n";
echo "cookiehttponly: " . ($CFG->cookiehttponly ?? 'not set') . "\n";
echo "sessioncookiepath: " . ($CFG->sessioncookiepath ?? 'not set') . "\n";

echo "\n=== 9. Test file serving via internal API ===\n";
// Check if the file is accessible programmatically
$fs = get_file_storage();
$allfiles = $fs->get_area_files($ctx->id, 'mod_book', 'chapter', false, 'filename', false);
echo "Files in book chapter area (context $ctx->id): " . count($allfiles) . "\n";
foreach (array_slice($allfiles, 0, 5) as $f) {
    echo "  " . $f->get_filename() . " (" . $f->get_filesize() . " bytes)\n";
}

echo "\n=== 10. Check Apache/PHP config for large files ===\n";
echo "post_max_size: " . ini_get('post_max_size') . "\n";
echo "upload_max_filesize: " . ini_get('upload_max_filesize') . "\n";
echo "memory_limit: " . ini_get('memory_limit') . "\n";
echo "max_execution_time: " . ini_get('max_execution_time') . "\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diagnose_images.php && php /tmp/diagnose_images.php 2>&1 && echo EXIT=0"

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

