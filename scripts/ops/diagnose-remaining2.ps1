# Find ALL book chapters across ALL courses that still reference hidden book contexts
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));

// Get all hidden book context IDs
$hiddenctxs = $DB->get_records_sql(
    "SELECT ctx.id as ctxid, cm.id as cmid, cm.instance as bookid, cm.course
     FROM {course_modules} cm
     JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
     WHERE cm.module = ? AND cm.visible = 0", array($bookmod));

echo "Hidden book contexts: ";
foreach ($hiddenctxs as $h) { echo "$h->ctxid(CM$h->cmid) "; }
echo "\n\n";

// Find ALL book chapters that still reference any hidden context
$allchapters = $DB->get_records_sql("SELECT bc.*, b.name as bookname, b.course
    FROM {book_chapters} bc JOIN {book} b ON b.id = bc.bookid");

$broken = array();
foreach ($allchapters as $ch) {
    foreach ($hiddenctxs as $h) {
        if (strpos($ch->content, "pluginfile.php/$h->ctxid/") !== false) {
            $cm = $DB->get_record_sql(
                "SELECT cm.id, cm.visible, ctx.id as ctxid FROM {course_modules} cm
                 JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
                 WHERE cm.module=? AND cm.instance=?", array($bookmod, $ch->bookid));
            $course = $DB->get_record('course', array('id' => $ch->course));
            echo "BROKEN: Ch $ch->id ($ch->title) in book '$ch->bookname' (CM $cm->id, ctx=$cm->ctxid)\n";
            echo "  Course: $course->fullname (id=$ch->course)\n";
            echo "  Refs hidden ctx $h->ctxid (CM $h->cmid, course $h->course)\n";
            // Extract the URLs
            preg_match_all('#pluginfile\.php/' . $h->ctxid . '/mod_book/(chapter|intro)/(\d+)/([^"\'<\s]+)#',
                $ch->content, $m, PREG_SET_ORDER);
            foreach ($m as $match) { echo "  URL: $match[0]\n"; }
            $broken[] = array('ch' => $ch, 'cm' => $cm, 'hiddenctx' => $h);
            echo "\n";
        }
    }
}

echo "\nTotal broken chapters: " . count($broken) . "\n";

// Also check for "Lecture and Quiz" or "Multiple Choice Exams" image issues
echo "\n=== Searching for 'Lecture' or 'Quiz' image references ===\n";
$searchTerms2 = array('Internal Med', 'Psychiatry', 'Choosing Wisely');
foreach ($searchTerms2 as $term) {
    $books2 = $DB->get_records_sql(
        "SELECT b.id, b.name, b.course, c.fullname FROM {book} b
         JOIN {course} c ON c.id = b.course WHERE b.name LIKE ?", array("%$term%"));
    foreach ($books2 as $bk) {
        $cm2 = $DB->get_record_sql(
            "SELECT cm.id, cm.visible, ctx.id as ctxid FROM {course_modules} cm
             JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
             WHERE cm.module=? AND cm.instance=?", array($bookmod, $bk->id));
        echo "\n  Book: $bk->name (id=$bk->id, CM=$cm2->id, ctx=$cm2->ctxid)\n";
        echo "  Course: $bk->fullname (id=$bk->course) visible=$cm2->visible\n";
        $chs = $DB->get_records('book_chapters', array('bookid' => $bk->id));
        foreach ($chs as $ch2) {
            $hasHidden = false;
            foreach ($hiddenctxs as $h2) {
                if (strpos($ch2->content, "pluginfile.php/$h2->ctxid/") !== false) {
                    echo "  Ch $ch2->id ($ch2->title): REFS HIDDEN ctx $h2->ctxid\n";
                    $hasHidden = true;
                }
            }
            if (!$hasHidden) {
                preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $ch2->content, $imgs);
                $imgcount = count($imgs[0]);
                echo "  Ch $ch2->id ($ch2->title): $imgcount imgs, OK\n";
            }
        }
    }
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag2.php && php /tmp/diag2.php 2>&1 && echo EXIT=0"
$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 600 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 120
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

