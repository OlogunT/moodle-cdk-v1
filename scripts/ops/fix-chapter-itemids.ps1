# Fix the itemid mismatch: files were copied with old chapter IDs that don't belong to the target books
# Need to: 1) find correct chapter IDs, 2) copy files with correct itemid, 3) update content URLs
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

$fs = get_file_storage();
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));
$fixed = 0;
$filescreated = 0;

// Get all hidden book CMs
$hiddenbooks = $DB->get_records_sql(
    "SELECT cm.id as cmid, cm.instance as bookid, cm.course, ctx.id as ctxid
     FROM {course_modules} cm
     JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
     WHERE cm.module = ? AND cm.visible = 0", array($bookmod));

echo "Hidden books: " . count($hiddenbooks) . "\n";

// For each hidden book, get its chapters and their files
foreach ($hiddenbooks as $hb) {
    $hiddenChapters = $DB->get_records('book_chapters', array('bookid' => $hb->bookid));
    echo "\n=== Hidden book $hb->bookid (CM $hb->cmid, ctx $hb->ctxid, course $hb->course) ===\n";
    echo "Hidden chapters: ";
    foreach ($hiddenChapters as $hch) { echo "$hch->id "; }
    echo "\n";

    // Get files from hidden chapters
    $hiddenFiles = array();
    foreach ($hiddenChapters as $hch) {
        $chfiles = $DB->get_records_sql(
            "SELECT * FROM {files} WHERE contextid = ? AND component = 'mod_book'
             AND filearea = 'chapter' AND itemid = ? AND filename != '.' AND filesize > 0",
            array($hb->ctxid, $hch->id));
        foreach ($chfiles as $cf) {
            $hiddenFiles[$hch->id][$cf->filename] = $cf;
        }
    }

    // Find all visible books in same course
    $visiblebooks = $DB->get_records_sql(
        "SELECT cm.id as cmid, cm.instance as bookid, ctx.id as ctxid
         FROM {course_modules} cm
         JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
         WHERE cm.module = ? AND cm.course = ? AND cm.visible = 1", array($bookmod, $hb->course));

    foreach ($visiblebooks as $vb) {
        $chapters = $DB->get_records('book_chapters', array('bookid' => $vb->bookid));
        foreach ($chapters as $ch) {
            // Check if this chapter content references any hidden chapter itemids
            $updated = false;
            $content = $ch->content;
            foreach ($hiddenChapters as $hch) {
                // Pattern: pluginfile.php/CORRECT_CTX/mod_book/chapter/OLD_ITEMID/filename
                // We already fixed ctx in previous script, so look for correct ctx but wrong itemid
                $pattern = "pluginfile.php/$vb->ctxid/mod_book/chapter/$hch->id/";
                if (strpos($content, $pattern) === false) continue;

                echo "  Ch $ch->id ($ch->title) in book CM $vb->cmid refs old itemid $hch->id\n";

                // Copy each file with the correct itemid = this chapter's ID
                if (isset($hiddenFiles[$hch->id])) {
                    foreach ($hiddenFiles[$hch->id] as $fname => $srcfile) {
                        $existing = $fs->get_file($vb->ctxid, 'mod_book', 'chapter', $ch->id, '/', $fname);
                        if (!$existing) {
                            $srcStored = $fs->get_file_by_id($srcfile->id);
                            if ($srcStored) {
                                $newrec = array(
                                    'contextid' => $vb->ctxid,
                                    'component' => 'mod_book',
                                    'filearea' => 'chapter',
                                    'itemid' => $ch->id,
                                    'filepath' => '/',
                                    'filename' => $fname
                                );
                                $fs->create_file_from_storedfile($newrec, $srcStored);
                                echo "    COPIED $fname -> ctx=$vb->ctxid item=$ch->id\n";
                                $filescreated++;
                            }
                        } else {
                            echo "    EXISTS $fname at ctx=$vb->ctxid item=$ch->id\n";
                        }
                    }
                }

                // Update content: replace old itemid with this chapter's id
                $content = str_replace(
                    "pluginfile.php/$vb->ctxid/mod_book/chapter/$hch->id/",
                    "pluginfile.php/$vb->ctxid/mod_book/chapter/$ch->id/",
                    $content);
                $updated = true;
            }

            if ($updated && $content !== $ch->content) {
                $DB->set_field('book_chapters', 'content', $content, array('id' => $ch->id));
                echo "    UPDATED ch $ch->id content\n";
                $fixed++;
            }
        }
    }
}

echo "\n=== Summary ===\n";
echo "Chapters updated: $fixed\n";
echo "Files copied: $filescreated\n";

echo "\n=== Purge caches + restart ===\n";
purge_all_caches();
echo "Caches purged\n";
exec('systemctl restart php-fpm 2>&1', $out, $ret);
echo "PHP-FPM: exit=$ret\n";
echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_itemids.php && php /tmp/fix_itemids.php 2>&1 && echo EXIT=0"

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

