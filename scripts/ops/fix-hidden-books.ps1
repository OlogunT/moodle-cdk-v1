# Find and fix hidden book activities that have content students need to access
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. CM 3905 details ===\n";
$cm3905 = $DB->get_record('course_modules', array('id' => 3905));
echo "CM 3905: visible=$cm3905->visible visibleoncoursepage=$cm3905->visibleoncoursepage\n";
echo "  deletioninprogress=$cm3905->deletioninprogress\n";

echo "\n=== 2. CM 3852 details ===\n";
$cm3852 = $DB->get_record('course_modules', array('id' => 3852));
echo "CM 3852: visible=$cm3852->visible instance=$cm3852->instance\n";
$book3852 = $DB->get_record('book', array('id' => $cm3852->instance));
echo "Book: $book3852->name (id=$book3852->id)\n";

echo "\n=== 3. All book CMs in course 113 ===\n";
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));
$bookcms = $DB->get_records('course_modules', array('course' => 113, 'module' => $bookmod));
foreach ($bookcms as $bcm) {
    $book = $DB->get_record('book', array('id' => $bcm->instance));
    $bctx = $DB->get_record('context', array('contextlevel' => 70, 'instanceid' => $bcm->id));
    $fcount = $DB->count_records_select('files', "contextid = ? AND filename != '.' AND filesize > 0", array($bctx->id));
    echo "CM $bcm->id: vis=$bcm->visible book=$book->name (id=$book->id) ctx=$bctx->id files=$fcount\n";
}

echo "\n=== 4. The page view.php?id=3852 shows book instance ===\n";
echo "When user visits /mod/book/view.php?id=3852, Moodle loads CM 3852\n";
echo "CM 3852 -> book instance $cm3852->instance\n";
echo "But the images in the book content reference /pluginfile.php/16799/...\n";
echo "Context 16799 -> CM 3905 -> book instance 261\n";
echo "CM 3905 is HIDDEN (visible=0)\n";
echo "So the images are embedded from a DIFFERENT hidden book!\n";

echo "\n=== 5. Check book chapter content for cross-references ===\n";
$chapters3852 = $DB->get_records('book_chapters', array('bookid' => $cm3852->instance));
echo "Book $cm3852->instance chapters:\n";
foreach ($chapters3852 as $ch) {
    $has16799 = strpos($ch->content, '16799') !== false;
    $has16719 = strpos($ch->content, '16719') !== false;
    echo "  Ch $ch->id ($ch->title): refs_16799=" . ($has16799 ? 'YES' : 'no') . " refs_16719=" . ($has16719 ? 'YES' : 'no') . "\n";
    if ($has16799) {
        // Extract the pluginfile URLs
        preg_match_all('/pluginfile\.php\/16799[^"\']+/', $ch->content, $matches);
        foreach ($matches[0] as $m) { echo "    URL: $m\n"; }
    }
}

echo "\n=== 6. Check chapters of book 261 (the hidden one) ===\n";
$chapters261 = $DB->get_records('book_chapters', array('bookid' => 261));
echo "Book 261 chapters:\n";
foreach ($chapters261 as $ch) {
    echo "  Ch $ch->id ($ch->title): hidden=$ch->hidden\n";
    preg_match_all('/pluginfile\.php\/16799[^"\']+/', $ch->content, $matches);
    if (!empty($matches[0])) {
        foreach ($matches[0] as $m) { echo "    URL: $m\n"; }
    }
}

echo "\n=== 7. How many hidden book CMs exist across ALL courses? ===\n";
$hiddenbooks = $DB->get_records_sql(
    "SELECT cm.id, cm.course, cm.instance, cm.visible, c.fullname
     FROM {course_modules} cm
     JOIN {course} c ON c.id = cm.course
     WHERE cm.module = ? AND cm.visible = 0",
    array($bookmod));
echo count($hiddenbooks) . " hidden book activities across all courses\n";
foreach ($hiddenbooks as $hb) {
    $book = $DB->get_record('book', array('id' => $hb->instance));
    echo "  CM $hb->id course=$hb->course ($hb->fullname): $book->name\n";
}

echo "\n=== 8. Check if making CM 3905 visible would fix it ===\n";
echo "Option A: Make CM 3905 visible (show the hidden book)\n";
echo "Option B: Update chapter content to use correct context IDs\n";
echo "Option C: The book content was likely duplicated/imported incorrectly\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_hidden.php && php /tmp/fix_hidden.php 2>&1 && echo EXIT=0"

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

