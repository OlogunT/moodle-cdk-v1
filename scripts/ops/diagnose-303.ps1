# Diagnose 303 redirect on pluginfile.php for student accounts
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

echo "=== 1. Check context 16799 ===\n";
$ctx16799 = $DB->get_record('context', array('id' => 16799));
if ($ctx16799) {
    $levels = [10=>'System',30=>'User',40=>'Category',50=>'Course',70=>'Module',80=>'Block'];
    echo "Context 16799: level=" . ($levels[$ctx16799->contextlevel] ?? $ctx16799->contextlevel) . " instanceid=$ctx16799->instanceid\n";
    if ($ctx16799->contextlevel == 70) {
        $cm = $DB->get_record('course_modules', array('id' => $ctx16799->instanceid));
        if ($cm) {
            $mod = $DB->get_record('modules', array('id' => $cm->module));
            echo "Module: " . ($mod ? $mod->name : 'unknown') . " instance=$cm->instance course=$cm->course visible=$cm->visible\n";
            $course = $DB->get_record('course', array('id' => $cm->course));
            echo "Course: $course->fullname (visible=$course->visible)\n";
        }
    }
} else {
    echo "Context 16799 NOT FOUND - this is the problem!\n";
}

echo "\n=== 2. Check context 16719 (from earlier diagnostic) ===\n";
$ctx16719 = $DB->get_record('context', array('id' => 16719));
if ($ctx16719) {
    echo "Context 16719: level=" . ($levels[$ctx16719->contextlevel] ?? $ctx16719->contextlevel) . " instanceid=$ctx16719->instanceid\n";
}

echo "\n=== 3. Search for the file by name ===\n";
$files = $DB->get_records_sql(
    "SELECT f.id, f.contextid, f.component, f.filearea, f.itemid, f.filename, f.filesize
     FROM {files} f
     WHERE f.filename LIKE '%Curricular%Advisory%Committee%' AND f.filename != '.'
     ORDER BY f.id"
);
echo "Found " . count($files) . " matching files:\n";
foreach ($files as $f) {
    echo "  id=$f->id ctx=$f->contextid comp=$f->component area=$f->filearea item=$f->itemid name=$f->filename size=$f->filesize\n";
}

echo "\n=== 4. Check file at context 16799, area chapter, item 840 ===\n";
$exactfile = $DB->get_record_sql(
    "SELECT * FROM {files}
     WHERE contextid = 16799 AND component = 'mod_book' AND filearea = 'chapter' AND itemid = 840
     AND filename != '.' AND filesize > 0"
);
if ($exactfile) {
    echo "FOUND: $exactfile->filename ($exactfile->filesize bytes)\n";
    echo "  contenthash: $exactfile->contenthash\n";
    echo "  mimetype: $exactfile->mimetype\n";
    // Check if file exists on disk
    $dir1 = substr($exactfile->contenthash, 0, 2);
    $dir2 = substr($exactfile->contenthash, 2, 2);
    $path = "$CFG->dataroot/filedir/$dir1/$dir2/$exactfile->contenthash";
    echo "  path: $path\n";
    echo "  exists: " . (file_exists($path) ? "YES" : "NO - FILE MISSING!") . "\n";
} else {
    echo "NO file found at ctx=16799 comp=mod_book area=chapter item=840\n";
    // Check what files ARE at context 16799
    $allfiles = $DB->get_records_sql(
        "SELECT id, component, filearea, itemid, filename, filesize FROM {files}
         WHERE contextid = 16799 AND filename != '.' AND filesize > 0"
    );
    echo "Files at context 16799: " . count($allfiles) . "\n";
    foreach (array_slice($allfiles, 0, 10) as $af) {
        echo "  comp=$af->component area=$af->filearea item=$af->itemid name=$af->filename\n";
    }
}

echo "\n=== 5. Check book chapter 840 ===\n";
$chapter = $DB->get_record('book_chapters', array('id' => 840));
if ($chapter) {
    echo "Chapter 840: bookid=$chapter->bookid title=$chapter->title hidden=$chapter->hidden\n";
    $book = $DB->get_record('book', array('id' => $chapter->bookid));
    if ($book) echo "Book: $book->name (course=$book->course)\n";
    // Find the correct CM for this book
    $bookcm = $DB->get_record('course_modules', array(
        'instance' => $chapter->bookid,
        'module' => $DB->get_field('modules', 'id', array('name' => 'book'))
    ));
    if ($bookcm) {
        echo "Book CM id: $bookcm->id\n";
        $bookctx = context_module::instance($bookcm->id);
        echo "Book context id: $bookctx->id\n";
    }
} else {
    echo "Chapter 840 NOT FOUND\n";
}

echo "\n=== 6. Student enrolment check ===\n";
$student = $DB->get_record('user', array('email' => 'connie.stanclik@gmail.com'));
if ($student && isset($cm)) {
    $enrol = $DB->get_records_sql(
        "SELECT ue.status, e.enrol, e.status as estatus FROM {user_enrolments} ue
         JOIN {enrol} e ON e.id = ue.enrolid WHERE ue.userid = ? AND e.courseid = ?",
        array($student->id, $cm->course)
    );
    if (empty($enrol)) {
        echo "Student NOT enrolled in course $cm->course\n";
    } else {
        foreach ($enrol as $e) {
            echo "Enrolled via $e->enrol: user_status=$e->status enrol_status=$e->estatus\n";
        }
    }
    // Check capability with the correct context
    if (isset($bookctx)) {
        $coursectx = context_course::instance($cm->course);
        echo "moodle/course:view: " . (has_capability('moodle/course:view', $coursectx, $student->id) ? 'YES' : 'NO') . "\n";
        echo "mod/book:read: " . (has_capability('mod/book:read', $bookctx, $student->id) ? 'YES' : 'NO') . "\n";
    }
}

echo "\n=== 7. Check pluginfile config ===\n";
echo "wwwroot: $CFG->wwwroot\n";
echo "slasharguments: " . ($CFG->slasharguments ?? 'not set') . "\n";
echo "forcelogin: " . ($CFG->forcelogin ?? '0') . "\n";
echo "sslproxy: " . ($CFG->sslproxy ?? 'not set') . "\n";
echo "reverseproxy: " . ($CFG->reverseproxy ?? 'not set') . "\n";

echo "\n=== 8. Check config.php for session settings ===\n";
echo "sessionhandler: " . (isset($CFG->session_handler_class) ? $CFG->session_handler_class : 'default') . "\n";
echo "sessioncookie: " . ($CFG->sessioncookie ?? 'default') . "\n";
echo "cookiesecure: " . ($CFG->cookiesecure ?? 'not set') . "\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag303.php && php /tmp/diag303.php 2>&1 && echo EXIT=0"

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

