$shellCmd = @'
echo "=== 1. Check course 114 via PHP ==="
php -r '
define("CLI_SCRIPT", true);
require("/app/moodle/config.php");
$course = $DB->get_record("course", array("id" => 114));
if ($course) {
    echo "Course found: " . $course->fullname . "\n";
    echo "Format: " . $course->format . "\n";
    echo "Category: " . $course->category . "\n";
    echo "Visible: " . $course->visible . "\n";
} else {
    echo "Course 114 NOT FOUND\n";
}

echo "\n=== 2. Check course format options ===\n";
$opts = $DB->get_records("course_format_options", array("courseid" => 114));
foreach ($opts as $o) {
    echo $o->name . " = " . $o->value . "\n";
}

echo "\n=== 3. Check for menutopic format ===\n";
$plugins = $DB->get_records_sql("SELECT plugin, version FROM {config_plugins} WHERE plugin LIKE \"%menutopic%\"");
foreach ($plugins as $p) {
    echo $p->plugin . " v" . $p->version . "\n";
}

echo "\n=== 4. Check format plugins on disk ===\n";
$formats = glob("/app/moodle/course/format/*/version.php");
foreach ($formats as $f) {
    echo basename(dirname($f)) . "\n";
}

echo "\n=== 5. Try loading course edit form ===\n";
try {
    require_once($CFG->dirroot . "/course/lib.php");
    require_once($CFG->dirroot . "/course/edit_form.php");
    echo "edit_form.php loaded OK\n";
} catch (Exception $e) {
    echo "ERROR: " . $e->getMessage() . "\n";
}

echo "\n=== 6. Debug the actual error ===\n";
$CFG->debug = E_ALL;
$CFG->debugdisplay = 1;
ini_set("display_errors", 1);
try {
    $courseformat = course_get_format($course);
    echo "Format class: " . get_class($courseformat) . "\n";
    $formatoptions = $courseformat->get_format_options();
    echo "Format options loaded OK\n";
} catch (Exception $e) {
    echo "ERROR: " . $e->getMessage() . "\n";
} catch (Error $e) {
    echo "FATAL: " . $e->getMessage() . " in " . $e->getFile() . ":" . $e->getLine() . "\n";
}
' 2>&1
echo "EXIT=$?"
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 120 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"

