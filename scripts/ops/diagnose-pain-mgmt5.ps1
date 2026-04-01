# Dump the actual HTML content of Pain Management chapters + check the SCORM module
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');
$fs = get_file_storage();

// Pain Management book chapters - dump HTML
$chapters = $DB->get_records('book_chapters', array('bookid' => 224), 'pagenum ASC');
foreach ($chapters as $ch) {
    echo "=== Chapter $ch->id: $ch->title ===\n";
    echo "CONTENT:\n$ch->content\n\n";
    echo "---END---\n\n";
}

// Check the SCORM module next to Pain Management (CM 3912)
echo "=== SCORM CM 3912 ===\n";
$scorm = $DB->get_record_sql(
    "SELECT s.*, cm.visible, ctx.id as ctxid FROM {scorm} s
     JOIN {course_modules} cm ON cm.instance = s.id AND cm.module = (SELECT id FROM {modules} WHERE name='scorm')
     JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
     WHERE cm.id = 3912");
if ($scorm) {
    echo "Name: $scorm->name\n";
    echo "Intro: $scorm->intro\n";
    echo "Visible: $scorm->visible\n";
    echo "Ctx: $scorm->ctxid\n";
    // Check for images in intro
    if (preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $scorm->intro, $imgs)) {
        foreach ($imgs[1] as $src) {
            echo "  IMG: $src\n";
            if (preg_match('#@@PLUGINFILE@@/([^"\'<\s?]+)#', $src, $pfm)) {
                $fname = urldecode(preg_replace('/\?.*$/', '', $pfm[1]));
                $file = $fs->get_file($scorm->ctxid, 'mod_scorm', 'intro', 0, '/', $fname);
                echo "    Status: " . ($file ? "OK (".$file->get_filesize().")" : "MISSING") . "\n";
            }
        }
    } else {
        echo "  No images in intro\n";
    }
}

// Check ALL labels in course 112 that have images
echo "\n=== ALL labels with images in course 112 ===\n";
$labels = $DB->get_records_sql(
    "SELECT l.id, l.intro, cm.id as cmid, cm.visible, ctx.id as ctxid
     FROM {label} l
     JOIN {course_modules} cm ON cm.instance = l.id AND cm.module = (SELECT id FROM {modules} WHERE name='label')
     JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
     WHERE l.course = 112 AND l.intro LIKE '%<img%'");
foreach ($labels as $l) {
    echo "  Label CM $l->cmid (vis=$l->visible ctx=$l->ctxid):\n";
    preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $l->intro, $imgs);
    foreach ($imgs[1] as $src) {
        $status = 'external';
        if (preg_match('#@@PLUGINFILE@@/([^"\'<\s?]+)#', $src, $pfm)) {
            $fname = urldecode(preg_replace('/\?.*$/', '', $pfm[1]));
            $file = $fs->get_file($l->ctxid, 'mod_label', 'intro', 0, '/', $fname);
            $status = $file ? "OK (".$file->get_filesize().")" : "MISSING";
        } elseif (preg_match('#pluginfile\.php/(\d+)/([^/]+)/([^/]+)/(\d+)/([^"\'<\s?]+)#', $src, $m)) {
            $file = $fs->get_file((int)$m[1], $m[2], $m[3], (int)$m[4], '/', urldecode($m[5]));
            $status = $file ? "OK" : "MISSING";
            if (!$file) {
                $octx = $DB->get_record('context', array('id' => (int)$m[1]));
                if ($octx && $octx->contextlevel == 70) {
                    $ocm = $DB->get_record('course_modules', array('id' => $octx->instanceid));
                    $status .= " ctx->CM $octx->instanceid vis=" . ($ocm ? $ocm->visible : '?');
                }
            }
        }
        echo "    $status: " . substr($src, 0, 100) . "\n";
    }
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_pain5.php && php /tmp/diag_pain5.php 2>&1 && echo EXIT=0"
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

