# Fix cross-referenced images: copy files from hidden book contexts to the correct contexts
# and update chapter content URLs across all courses
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');

$fs = get_file_storage();
$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));
$fixed = 0;
$filescreated = 0;

// Get all hidden book CMs (these are the "sample books" with misreferenced files)
$hiddenbooks = $DB->get_records_sql(
    "SELECT cm.id as cmid, cm.course, cm.instance, ctx.id as ctxid
     FROM {course_modules} cm
     JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
     WHERE cm.module = ? AND cm.visible = 0",
    array($bookmod));

echo "Found " . count($hiddenbooks) . " hidden book CMs\n\n";

foreach ($hiddenbooks as $hb) {
    $hiddenctxid = $hb->ctxid;
    echo "=== Hidden book CM $hb->cmid (ctx=$hiddenctxid, course=$hb->course) ===\n";

    // Find all visible book chapters in the SAME course that reference this hidden context
    $visiblebooks = $DB->get_records_sql(
        "SELECT cm.id as cmid, cm.instance, ctx.id as ctxid
         FROM {course_modules} cm
         JOIN {context} ctx ON ctx.contextlevel = 70 AND ctx.instanceid = cm.id
         WHERE cm.module = ? AND cm.course = ? AND cm.visible = 1",
        array($bookmod, $hb->course));

    foreach ($visiblebooks as $vb) {
        $chapters = $DB->get_records('book_chapters', array('bookid' => $vb->instance));
        foreach ($chapters as $ch) {
            $pattern = "pluginfile.php/$hiddenctxid/";
            if (strpos($ch->content, $pattern) === false) continue;

            echo "  Chapter $ch->id ($ch->title) in book CM $vb->cmid references hidden ctx $hiddenctxid\n";

            // Find all files referenced from the hidden context in this chapter
            preg_match_all(
                '#@@PLUGINFILE@@/([^"\'<]+)|pluginfile\.php/' . $hiddenctxid . '/mod_book/chapter/(\d+)/([^"\'<]+)#',
                $ch->content, $matches, PREG_SET_ORDER);

            // Get all unique file references
            $refs = array();
            preg_match_all(
                '#pluginfile\.php/' . $hiddenctxid . '/mod_book/(chapter|intro)/(\d+)/([^"\'<\s]+)#',
                $ch->content, $matches2, PREG_SET_ORDER);

            foreach ($matches2 as $m) {
                $area = $m[1];
                $itemid = (int)$m[2];
                $filename = urldecode($m[3]);
                $refs["$area/$itemid/$filename"] = array('area' => $area, 'itemid' => $itemid, 'filename' => $filename);
            }

            foreach ($refs as $key => $ref) {
                // Check if file exists in hidden context
                $srcfile = $fs->get_file($hiddenctxid, 'mod_book', $ref['area'], $ref['itemid'], '/', $ref['filename']);
                if (!$srcfile) {
                    echo "    SKIP: $key not found in hidden ctx\n";
                    continue;
                }

                // Check if file already exists in target context
                $dstfile = $fs->get_file($vb->ctxid, 'mod_book', $ref['area'], $ref['itemid'], '/', $ref['filename']);
                if (!$dstfile) {
                    // Copy file to correct context
                    $newrecord = array(
                        'contextid' => $vb->ctxid,
                        'component' => 'mod_book',
                        'filearea' => $ref['area'],
                        'itemid' => $ref['itemid'],
                        'filepath' => '/',
                        'filename' => $ref['filename']
                    );
                    $fs->create_file_from_storedfile($newrecord, $srcfile);
                    echo "    COPIED: $key -> ctx $vb->ctxid\n";
                    $filescreated++;
                } else {
                    echo "    EXISTS: $key already in ctx $vb->ctxid\n";
                }
            }

            // Now update the chapter content to use the correct context ID
            $newcontent = str_replace(
                "pluginfile.php/$hiddenctxid/",
                "pluginfile.php/$vb->ctxid/",
                $ch->content);

            if ($newcontent !== $ch->content) {
                $DB->set_field('book_chapters', 'content', $newcontent, array('id' => $ch->id));
                echo "    UPDATED chapter $ch->id content: ctx $hiddenctxid -> $vb->ctxid\n";
                $fixed++;
            }
        }
    }
}

echo "\n=== Summary ===\n";
echo "Chapters updated: $fixed\n";
echo "Files copied: $filescreated\n";

echo "\n=== Purge caches ===\n";
purge_all_caches();
echo "Caches purged\n";

echo "\n=== Restart PHP-FPM ===\n";
exec('systemctl restart php-fpm 2>&1', $out, $ret);
echo "PHP-FPM restart: exit=$ret\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_xref.php && php /tmp/fix_xref.php 2>&1 && echo EXIT=0"

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

