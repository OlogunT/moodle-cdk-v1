# Diagnose remaining broken images in specific books
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

$fs = get_file_storage();
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));

// Search for books matching the reported names
$searchTerms = array('Sensitive Clinical', 'Anesthesiology', 'Pediatrics', 'Internal Med', 'Psychiatry', 'Choosing Wisely');

foreach ($searchTerms as $term) {
    echo "\n========== Searching: $term ==========\n";
    $books = $DB->get_records_sql(
        "SELECT b.id, b.name, b.course, c.fullname as coursename
         FROM {book} b JOIN {course} c ON c.id = b.course
         WHERE b.name LIKE ?", array("%$term%"));

    foreach ($books as $book) {
        $cm = $DB->get_record_sql(
            "SELECT cm.id, cm.visible, ctx.id as ctxid
             FROM {course_modules} cm
             JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
             WHERE cm.module = ? AND cm.instance = ?", array($bookmod, $book->id));

        if (!$cm) { echo "  No CM for book $book->id\n"; continue; }

        echo "\n  Book: $book->name (id=$book->id)\n";
        echo "  Course: $book->coursename (id=$book->course)\n";
        echo "  CM: $cm->id visible=$cm->visible ctx=$cm->ctxid\n";

        // Get chapters
        $chapters = $DB->get_records('book_chapters', array('bookid' => $book->id), 'pagenum ASC');
        foreach ($chapters as $ch) {
            echo "\n  Chapter $ch->id: $ch->title (hidden=$ch->hidden)\n";

            // Find image references in content
            preg_match_all('#pluginfile\.php/(\d+)/mod_book/(chapter|intro)/(\d+)/([^"\'<\s]+)#', $ch->content, $matches, PREG_SET_ORDER);
            if (empty($matches)) {
                // Check for @@PLUGINFILE@@ references
                preg_match_all('#@@PLUGINFILE@@/([^"\'<\s]+)#', $ch->content, $pfmatches, PREG_SET_ORDER);
                if (!empty($pfmatches)) {
                    echo "    Uses @@PLUGINFILE@@ references:\n";
                    foreach ($pfmatches as $m) {
                        $fname = urldecode($m[1]);
                        $file = $fs->get_file($cm->ctxid, 'mod_book', 'chapter', $ch->id, '/', $fname);
                        echo "      $fname -> " . ($file ? "EXISTS (size=" . $file->get_filesize() . ")" : "MISSING") . "\n";
                    }
                } else {
                    // Check if there are any img tags at all
                    preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $ch->content, $imgmatches, PREG_SET_ORDER);
                    if (empty($imgmatches)) {
                        echo "    No image references found in content\n";
                        // Show first 500 chars of content for inspection
                        echo "    Content preview: " . substr(strip_tags($ch->content), 0, 200) . "\n";
                    } else {
                        echo "    Image URLs found:\n";
                        foreach ($imgmatches as $im) {
                            echo "      $im[1]\n";
                        }
                    }
                }
            } else {
                foreach ($matches as $m) {
                    $ctxid = (int)$m[1];
                    $area = $m[2];
                    $itemid = (int)$m[3];
                    $fname = urldecode($m[4]);
                    echo "    IMG: ctx=$ctxid area=$area item=$itemid file=$fname\n";

                    // Check context ownership
                    if ($ctxid != $cm->ctxid) {
                        echo "      WARNING: ctx $ctxid != book ctx $cm->ctxid\n";
                        $otherctx = $DB->get_record('context', array('id' => $ctxid));
                        if ($otherctx) {
                            $othercm = $DB->get_record('course_modules', array('id' => $otherctx->instanceid));
                            echo "      Belongs to CM $otherctx->instanceid visible=" . ($othercm ? $othercm->visible : '?') . "\n";
                        }
                    }

                    // Check itemid ownership
                    if ($area == 'chapter' && $itemid != $ch->id) {
                        $otherch = $DB->get_record('book_chapters', array('id' => $itemid));
                        if ($otherch) {
                            echo "      WARNING: itemid $itemid belongs to book $otherch->bookid, not $book->id\n";
                        } else {
                            echo "      WARNING: chapter $itemid does not exist!\n";
                        }
                    }

                    // Check file exists
                    $file = $fs->get_file($ctxid, 'mod_book', $area, $itemid, '/', $fname);
                    echo "      File in DB: " . ($file ? "YES size=" . $file->get_filesize() : "MISSING") . "\n";
                }
            }

            // Check files stored for this chapter
            $storedFiles = $DB->get_records_sql(
                "SELECT id, filename, filesize, contextid, itemid FROM {files}
                 WHERE component = 'mod_book' AND filearea = 'chapter'
                 AND itemid = ? AND filename != '.' AND filesize > 0",
                array($ch->id));
            if (!empty($storedFiles)) {
                echo "    Stored files for this chapter (item=$ch->id):\n";
                foreach ($storedFiles as $sf) {
                    echo "      ctx=$sf->contextid $sf->filename ($sf->filesize bytes)\n";
                }
            }
        }
    }
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_remaining.php && php /tmp/diag_remaining.php 2>&1 && echo EXIT=0"

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

