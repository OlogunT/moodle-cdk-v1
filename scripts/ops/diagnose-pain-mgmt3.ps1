# Deep dive: check ALL image references in Pain Management book chapters for broken rendering
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');
$fs = get_file_storage();

// Check both Foundations courses
$bookIds = array(224); // Pain Management in Foundations 2026
// Also check the old Foundations course 73 - "Chronic Pain & Substance Use Disorder"
$book73 = $DB->get_records_sql("SELECT id, name FROM {book} WHERE course = 73 AND name LIKE '%Pain%'");
foreach ($book73 as $b) { $bookIds[] = $b->id; }

$bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));

foreach ($bookIds as $bid) {
    $book = $DB->get_record('book', array('id' => $bid));
    $cm = $DB->get_record_sql(
        "SELECT cm.id, cm.visible, ctx.id as ctxid FROM {course_modules} cm
         JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
         WHERE cm.module=? AND cm.instance=?", array($bookmod, $bid));

    echo "=== Book $bid: $book->name (CM=$cm->id ctx=$cm->ctxid) ===\n\n";

    $chapters = $DB->get_records('book_chapters', array('bookid' => $bid), 'pagenum ASC');
    foreach ($chapters as $ch) {
        echo "--- Chapter $ch->id: $ch->title ---\n";

        // Show ALL img tags with full src
        preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $ch->content, $imgs, PREG_SET_ORDER);
        echo "  Total <img> tags: " . count($imgs) . "\n";

        foreach ($imgs as $i => $im) {
            $src = $im[1];
            echo "  [$i] $src\n";

            // Check if it's a pluginfile URL
            if (preg_match('#pluginfile\.php/(\d+)/([^/]+)/([^/]+)/(\d+)/([^"\'<\s?]+)#', $src, $m)) {
                $ctxid = (int)$m[1]; $comp = $m[2]; $area = $m[3]; $itemid = (int)$m[4];
                $fname = urldecode($m[5]);
                $file = $fs->get_file($ctxid, $comp, $area, $itemid, '/', $fname);
                if (!$file) {
                    echo "      STATUS: MISSING (ctx=$ctxid comp=$comp area=$area item=$itemid file=$fname)\n";
                    // Check if ctx belongs to hidden CM
                    $ctx = $DB->get_record('context', array('id' => $ctxid));
                    if ($ctx && $ctx->contextlevel == 70) {
                        $ocm = $DB->get_record('course_modules', array('id' => $ctx->instanceid));
                        echo "      CTX belongs to CM $ctx->instanceid visible=" . ($ocm ? $ocm->visible : '?') . "\n";
                    }
                } else {
                    echo "      STATUS: OK (" . $file->get_filesize() . " bytes)\n";
                }
            } elseif (strpos($src, '@@PLUGINFILE@@') !== false) {
                preg_match('#@@PLUGINFILE@@/([^"\'<\s?]+)#', $src, $pfm);
                $fname = urldecode(preg_replace('/\?.*$/', '', $pfm[1]));
                $file = $fs->get_file($cm->ctxid, 'mod_book', 'chapter', $ch->id, '/', $fname);
                if (!$file) {
                    echo "      STATUS: MISSING (@@PLUGINFILE@@ $fname not at ctx=$cm->ctxid item=$ch->id)\n";
                    // Check if file exists anywhere
                    $anywhere = $DB->get_records_sql(
                        "SELECT id, contextid, itemid FROM {files} WHERE filename = ? AND filesize > 0 LIMIT 5",
                        array($fname));
                    foreach ($anywhere as $af) {
                        echo "      FOUND ELSEWHERE: ctx=$af->contextid item=$af->itemid\n";
                    }
                } else {
                    echo "      STATUS: OK (" . $file->get_filesize() . " bytes)\n";
                }
            } else {
                echo "      STATUS: external URL\n";
            }
        }
        echo "\n";
    }
}

// Also check if connis.s.oconnor is enrolled in the right course
$user = $DB->get_record_sql("SELECT id, username, email FROM {user} WHERE username LIKE '%oconnor%' OR email LIKE '%oconnor%'");
if ($user) {
    echo "\n=== User: $user->username ($user->email, id=$user->id) ===\n";
    $enrols = $DB->get_records_sql(
        "SELECT ue.id, e.courseid, c.fullname, r.shortname
         FROM {user_enrolments} ue
         JOIN {enrol} e ON e.id = ue.enrolid
         JOIN {course} c ON c.id = e.courseid
         LEFT JOIN {role_assignments} ra ON ra.userid = ue.userid AND ra.contextid = (
             SELECT id FROM {context} WHERE contextlevel = 50 AND instanceid = e.courseid)
         LEFT JOIN {role} r ON r.id = ra.roleid
         WHERE ue.userid = ?", array($user->id));
    foreach ($enrols as $en) {
        echo "  Course $en->courseid: $en->fullname (role=$en->shortname)\n";
    }
} else {
    echo "\nUser oconnor not found\n";
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_pain3.php && php /tmp/diag_pain3.php 2>&1 && echo EXIT=0"
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

