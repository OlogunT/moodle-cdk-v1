$shellCmd = @'
echo "=== 1. Check menutopic plugin ==="
ls -la /app/moodle/course/format/menutopic/ 2>&1 | head -5
echo ""

echo "=== 2. Check format plugins in DB ==="
php -r '
define("CLI_SCRIPT", true);
require("/app/moodle/config.php");
$recs = $DB->get_records_sql("SELECT plugin, version FROM {config_plugins} WHERE plugin LIKE ?", array("%format_%"));
foreach ($recs as $r) { echo $r->plugin . " = " . $r->version . "\n"; }
' 2>&1
echo ""

echo "=== 3. Simulate course edit page ==="
php -r '
define("CLI_SCRIPT", true);
error_reporting(E_ALL);
ini_set("display_errors", 1);
require("/app/moodle/config.php");
$CFG->debug = E_ALL;
$CFG->debugdisplay = 1;
require_once($CFG->dirroot . "/course/lib.php");
$course = $DB->get_record("course", array("id" => 114), "*", MUST_EXIST);
echo "Course: " . $course->fullname . "\n";
echo "Format: " . $course->format . "\n";

// Try what edit.php does
require_once($CFG->dirroot . "/lib/formslib.php");
require_once($CFG->dirroot . "/course/edit_form.php");
echo "Forms loaded OK\n";

// Get course context
$context = context_course::instance($course->id);
echo "Context: " . $context->id . "\n";

// Check custom fields
$handler = core_course\customfield\course_handler::create();
$customfields = $handler->get_instance_data($course->id);
echo "Custom fields: " . count($customfields) . "\n";

// Check enrolment plugins
$enrols = enrol_get_instances($course->id, true);
echo "Enrol instances: " . count($enrols) . "\n";

echo "All checks passed\n";
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

