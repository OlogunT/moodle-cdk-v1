# Search for Pain Management across ALL module types in ALL Foundations courses
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');
$fs = get_file_storage();

// Find all Foundations courses
$courses = $DB->get_records_sql("SELECT id, fullname FROM {course} WHERE fullname LIKE '%Foundations%'");
echo "=== Foundations courses ===\n";
foreach ($courses as $c) { echo "  id=$c->id: $c->fullname\n"; }

// Search for Pain Management in ALL module types across Foundations courses
foreach ($courses as $c) {
    echo "\n=== Course: $c->fullname (id=$c->id) ===\n";

    // Books
    $books = $DB->get_records_sql(
        "SELECT b.id, b.name FROM {book} b WHERE b.course = ? AND b.name LIKE '%Pain%'", array($c->id));
    foreach ($books as $b) {
        $bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));
        $cm = $DB->get_record_sql(
            "SELECT cm.id, cm.visible, ctx.id as ctxid FROM {course_modules} cm
             JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
             WHERE cm.module=? AND cm.instance=?", array($bookmod, $b->id));
        echo "  BOOK: $b->name (CM=$cm->id vis=$cm->visible ctx=$cm->ctxid)\n";
        $chs = $DB->get_records('book_chapters', array('bookid' => $b->id));
        foreach ($chs as $ch) {
            // Check all img sources
            preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $ch->content, $imgs);
            $broken = 0;
            foreach ($imgs[1] as $src) {
                if (preg_match('#pluginfile\.php/(\d+)/mod_book/(chapter|intro)/(\d+)/([^"\'<\s?]+)#', $src, $m)) {
                    $file = $fs->get_file((int)$m[1], 'mod_book', $m[2], (int)$m[3], '/', urldecode($m[4]));
                    if (!$file) { echo "    BROKEN IMG in ch $ch->id ($ch->title): $src\n"; $broken++; }
                } elseif (preg_match('#@@PLUGINFILE@@/([^"\'<\s?]+)#', $src, $m)) {
                    $fname = urldecode(preg_replace('/\?.*$/', '', $m[1]));
                    $file = $fs->get_file($cm->ctxid, 'mod_book', 'chapter', $ch->id, '/', $fname);
                    if (!$file) { echo "    BROKEN @@PF@@ in ch $ch->id ($ch->title): $fname\n"; $broken++; }
                }
            }
            if ($broken == 0 && count($imgs[0]) > 0) {
                echo "    Ch $ch->id ($ch->title): " . count($imgs[0]) . " imgs ALL OK\n";
            } elseif (count($imgs[0]) == 0) {
                echo "    Ch $ch->id ($ch->title): no images\n";
            }
        }
    }

    // Labels with Pain Management
    $labels = $DB->get_records_sql(
        "SELECT l.id, l.name, l.intro, cm.id as cmid, ctx.id as ctxid, cm.visible
         FROM {label} l
         JOIN {course_modules} cm ON cm.instance = l.id AND cm.module = (SELECT id FROM {modules} WHERE name='label')
         JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
         WHERE l.course = ? AND (l.name LIKE '%Pain%' OR l.intro LIKE '%Pain%')", array($c->id));
    foreach ($labels as $l) {
        if (strpos($l->intro, '<img') !== false) {
            echo "  LABEL: $l->name (CM=$l->cmid vis=$l->visible)\n";
            preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $l->intro, $imgs);
            foreach ($imgs[1] as $src) { echo "    IMG: $src\n"; }
        }
    }

    // Pages with Pain
    $pages = $DB->get_records_sql(
        "SELECT p.id, p.name, p.content, cm.id as cmid, ctx.id as ctxid, cm.visible
         FROM {page} p
         JOIN {course_modules} cm ON cm.instance = p.id AND cm.module = (SELECT id FROM {modules} WHERE name='page')
         JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
         WHERE p.course = ? AND p.name LIKE '%Pain%'", array($c->id));
    foreach ($pages as $p) {
        echo "  PAGE: $p->name (CM=$p->cmid vis=$p->visible)\n";
        preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $p->content, $imgs);
        foreach ($imgs[1] as $src) { echo "    IMG: $src\n"; }
    }

    // Also check ALL modules in this course for hidden context refs
    $allcms = $DB->get_records_sql(
        "SELECT cm.id, cm.visible, m.name as modname, ctx.id as ctxid
         FROM {course_modules} cm
         JOIN {modules} m ON m.id = cm.module
         JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
         WHERE cm.course = ? AND m.name = 'book'
         ORDER BY cm.id", array($c->id));
    echo "\n  All book CMs in course $c->id:\n";
    foreach ($allcms as $acm) {
        $bk = $DB->get_record_sql("SELECT name FROM {book} WHERE id = (SELECT instance FROM {course_modules} WHERE id=?)", array($acm->id));
        $name = $bk ? $bk->name : '?';
        echo "    CM $acm->id vis=$acm->visible ctx=$acm->ctxid: $name\n";
    }
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_pain2.php && php /tmp/diag_pain2.php 2>&1 && echo EXIT=0"
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

