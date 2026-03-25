# Diagnose missing image in Pain Management book in Foundations course
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

$fs = get_file_storage();
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));

// Find Pain Management books
$books = $DB->get_records_sql(
    "SELECT b.id, b.name, b.course, c.fullname FROM {book} b
     JOIN {course} c ON c.id = b.course WHERE b.name LIKE ?", array('%Pain Management%'));

foreach ($books as $book) {
    $cm = $DB->get_record_sql(
        "SELECT cm.id, cm.visible, ctx.id as ctxid FROM {course_modules} cm
         JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
         WHERE cm.module=? AND cm.instance=?", array($bookmod, $book->id));
    if (!$cm) continue;

    echo "=== Book: $book->name (id=$book->id) ===\n";
    echo "Course: $book->fullname (id=$book->course)\n";
    echo "CM: $cm->id visible=$cm->visible ctx=$cm->ctxid\n\n";

    $chapters = $DB->get_records('book_chapters', array('bookid' => $book->id), 'pagenum ASC');
    foreach ($chapters as $ch) {
        echo "Chapter $ch->id: $ch->title (hidden=$ch->hidden)\n";

        // Check for hidden context refs
        $hiddenctxs = $DB->get_records_sql(
            "SELECT ctx.id as ctxid, cm.id as cmid, cm.visible FROM {course_modules} cm
             JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
             WHERE cm.module=? AND cm.visible=0", array($bookmod));
        foreach ($hiddenctxs as $h) {
            if (strpos($ch->content, "pluginfile.php/$h->ctxid/") !== false) {
                echo "  WARNING: refs hidden ctx $h->ctxid (CM $h->cmid)\n";
                preg_match_all('#pluginfile\.php/' . $h->ctxid . '/[^"\'<\s]+#', $ch->content, $m);
                foreach ($m[0] as $url) { echo "    URL: $url\n"; }
            }
        }

        // Check pluginfile URLs
        preg_match_all('#pluginfile\.php/(\d+)/mod_book/(chapter|intro)/(\d+)/([^"\'<\s]+)#', $ch->content, $matches, PREG_SET_ORDER);
        if (!empty($matches)) {
            foreach ($matches as $m) {
                $ctxid = (int)$m[1]; $area = $m[2]; $itemid = (int)$m[3]; $fname = urldecode($m[4]);
                $file = $fs->get_file($ctxid, 'mod_book', $area, $itemid, '/', $fname);
                $status = $file ? "OK (size=" . $file->get_filesize() . ")" : "MISSING";
                $ctxmatch = ($ctxid == $cm->ctxid) ? "" : " WRONG_CTX";
                $itemmatch = ($itemid == $ch->id) ? "" : " WRONG_ITEM(should be $ch->id)";
                echo "  IMG: ctx=$ctxid/$area/$itemid/$fname -> $status$ctxmatch$itemmatch\n";
            }
        }

        // Check @@PLUGINFILE@@ refs
        preg_match_all('#@@PLUGINFILE@@/([^"\'<\s]+)#', $ch->content, $pfm, PREG_SET_ORDER);
        if (!empty($pfm)) {
            foreach ($pfm as $p) {
                $fname = urldecode(preg_replace('/\?.*$/', '', $p[1]));
                $file = $fs->get_file($cm->ctxid, 'mod_book', 'chapter', $ch->id, '/', $fname);
                echo "  @@PLUGINFILE@@: $fname -> " . ($file ? "OK (size=" . $file->get_filesize() . ")" : "MISSING") . "\n";
            }
        }

        // Check all img tags
        preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $ch->content, $imgs, PREG_SET_ORDER);
        if (empty($matches) && empty($pfm) && !empty($imgs)) {
            foreach ($imgs as $im) { echo "  IMG_TAG: $im[1]\n"; }
        }

        // Stored files
        $stored = $DB->get_records_sql(
            "SELECT id, filename, filesize, contextid, itemid FROM {files}
             WHERE component='mod_book' AND filearea='chapter' AND itemid=? AND filename!='.' AND filesize>0",
            array($ch->id));
        if (!empty($stored)) {
            echo "  Stored files (item=$ch->id):\n";
            foreach ($stored as $sf) { echo "    ctx=$sf->contextid $sf->filename ($sf->filesize)\n"; }
        }
        echo "\n";
    }
}

echo "Done\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_pain.php && php /tmp/diag_pain.php 2>&1 && echo EXIT=0"
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

