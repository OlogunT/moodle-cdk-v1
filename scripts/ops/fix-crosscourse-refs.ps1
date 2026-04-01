# Fix ALL remaining cross-course hidden book references
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

$fs = get_file_storage();
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));
$fixed = 0;
$filescreated = 0;

// Get all hidden book context IDs and their chapters/files
$hiddenctxs = $DB->get_records_sql(
    "SELECT ctx.id as ctxid, cm.id as cmid, cm.instance as bookid, cm.course
     FROM {course_modules} cm
     JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
     WHERE cm.module = ? AND cm.visible = 0", array($bookmod));

// Build map of hidden chapter files
$hiddenFiles = array();
foreach ($hiddenctxs as $h) {
    $chapters = $DB->get_records('book_chapters', array('bookid' => $h->bookid));
    foreach ($chapters as $hch) {
        $chfiles = $DB->get_records_sql(
            "SELECT * FROM {files} WHERE contextid = ? AND component = 'mod_book'
             AND filearea = 'chapter' AND itemid = ? AND filename != '.' AND filesize > 0",
            array($h->ctxid, $hch->id));
        foreach ($chfiles as $cf) {
            $hiddenFiles[$h->ctxid][$hch->id][$cf->filename] = $cf;
        }
    }
}

// Scan ALL book chapters across ALL courses for hidden context references
$allchapters = $DB->get_records_sql(
    "SELECT bc.*, b.name as bookname FROM {book_chapters} bc JOIN {book} b ON b.id = bc.bookid");

foreach ($allchapters as $ch) {
    $content = $ch->content;
    $updated = false;

    foreach ($hiddenctxs as $h) {
        if (strpos($content, "pluginfile.php/$h->ctxid/") === false) continue;

        // Get this chapter's book CM and context
        $cm = $DB->get_record_sql(
            "SELECT cm.id, cm.visible, ctx.id as ctxid FROM {course_modules} cm
             JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
             WHERE cm.module=? AND cm.instance=?", array($bookmod, $ch->bookid));

        if (!$cm || $cm->visible == 0) continue; // Skip hidden books themselves

        echo "FIX: Ch $ch->id ($ch->title) in '$ch->bookname' (CM $cm->id, ctx=$cm->ctxid)\n";

        // Find all URL patterns referencing this hidden context
        $hchapters = $DB->get_records('book_chapters', array('bookid' => $h->bookid));
        foreach ($hchapters as $hch) {
            $oldPattern = "pluginfile.php/$h->ctxid/mod_book/chapter/$hch->id/";
            if (strpos($content, $oldPattern) === false) continue;

            echo "  Replacing ctx=$h->ctxid item=$hch->id -> ctx=$cm->ctxid item=$ch->id\n";

            // Copy files with correct context and itemid
            if (isset($hiddenFiles[$h->ctxid][$hch->id])) {
                foreach ($hiddenFiles[$h->ctxid][$hch->id] as $fname => $srcfile) {
                    $existing = $fs->get_file($cm->ctxid, 'mod_book', 'chapter', $ch->id, '/', $fname);
                    if (!$existing) {
                        $srcStored = $fs->get_file_by_id($srcfile->id);
                        if ($srcStored) {
                            $newrec = array(
                                'contextid' => $cm->ctxid,
                                'component' => 'mod_book',
                                'filearea' => 'chapter',
                                'itemid' => $ch->id,
                                'filepath' => '/',
                                'filename' => $fname
                            );
                            $fs->create_file_from_storedfile($newrec, $srcStored);
                            echo "    COPIED $fname -> ctx=$cm->ctxid item=$ch->id\n";
                            $filescreated++;
                        }
                    } else {
                        echo "    EXISTS $fname\n";
                    }
                }
            }

            // Update content
            $content = str_replace($oldPattern, "pluginfile.php/$cm->ctxid/mod_book/chapter/$ch->id/", $content);
            $updated = true;
        }
    }

    if ($updated && $content !== $ch->content) {
        $DB->set_field('book_chapters', 'content', $content, array('id' => $ch->id));
        echo "  UPDATED ch $ch->id\n\n";
        $fixed++;
    }
}

echo "\n=== Summary ===\n";
echo "Chapters updated: $fixed\n";
echo "Files copied: $filescreated\n";

purge_all_caches();
echo "Caches purged\n";
exec('systemctl restart php-fpm 2>&1', $out, $ret);
echo "PHP-FPM: exit=$ret\n";
echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_xc.php && php /tmp/fix_xc.php 2>&1 && echo EXIT=0"
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

