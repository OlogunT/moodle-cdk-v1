# Check user accounts for oconnor + find ALL modules in Pain Management section + check labels/pages with images
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/filelib.php');
$fs = get_file_storage();

// 1. Find ALL oconnor user accounts
echo "=== All oconnor accounts ===\n";
$users = $DB->get_records_sql(
    "SELECT id, username, email, firstname, lastname, suspended, deleted, auth
     FROM {user} WHERE username LIKE '%oconnor%' OR email LIKE '%oconnor%'
     ORDER BY id");
foreach ($users as $u) {
    echo "  id=$u->id user='$u->username' email='$u->email' name='$u->firstname $u->lastname' "
       . "susp=$u->suspended del=$u->deleted auth=$u->auth\n";
    // Check enrollments
    $enrols = $DB->get_records_sql(
        "SELECT e.courseid, c.fullname FROM {user_enrolments} ue
         JOIN {enrol} e ON e.id = ue.enrolid
         JOIN {course} c ON c.id = e.courseid
         WHERE ue.userid = ?", array($u->id));
    foreach ($enrols as $en) {
        echo "    enrolled: course $en->courseid ($en->fullname)\n";
    }
}

// 2. Find the section containing Pain Management in Foundations 2026 (course 112)
echo "\n=== Section containing Pain Management (CM 3806) in course 112 ===\n";
$section = $DB->get_record_sql(
    "SELECT cs.id, cs.section, cs.name, cs.sequence FROM {course_sections} cs
     WHERE cs.course = 112 AND cs.sequence LIKE '%3806%'");
if ($section) {
    echo "Section $section->section: $section->name\n";
    echo "Sequence: $section->sequence\n\n";
    $cmids = explode(',', $section->sequence);
    foreach ($cmids as $cmid) {
        $cmid = trim($cmid);
        if (!$cmid) continue;
        $cm = $DB->get_record_sql(
            "SELECT cm.id, cm.visible, m.name as modname, cm.instance, ctx.id as ctxid
             FROM {course_modules} cm
             JOIN {modules} m ON m.id = cm.module
             JOIN {context} ctx ON ctx.contextlevel=70 AND ctx.instanceid=cm.id
             WHERE cm.id = ?", array($cmid));
        if (!$cm) { echo "  CM $cmid: NOT FOUND\n"; continue; }

        $modname = '';
        if ($cm->modname == 'book') {
            $mod = $DB->get_record('book', array('id' => $cm->instance));
            $modname = $mod ? $mod->name : '?';
        } elseif ($cm->modname == 'label') {
            $mod = $DB->get_record('label', array('id' => $cm->instance));
            $modname = $mod ? substr(strip_tags($mod->intro), 0, 60) : '?';
            // Check for images in label
            if ($mod && preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $mod->intro, $imgs)) {
                foreach ($imgs[1] as $src) {
                    $status = 'external';
                    if (preg_match('#@@PLUGINFILE@@/([^"\'<\s?]+)#', $src, $pfm)) {
                        $fname = urldecode(preg_replace('/\?.*$/', '', $pfm[1]));
                        $file = $fs->get_file($cm->ctxid, 'mod_label', 'intro', 0, '/', $fname);
                        $status = $file ? 'OK ('.$file->get_filesize().')' : 'MISSING';
                    } elseif (preg_match('#pluginfile\.php/(\d+)/([^/]+)/([^/]+)/(\d+)/([^"\'<\s?]+)#', $src, $m)) {
                        $file = $fs->get_file((int)$m[1], $m[2], $m[3], (int)$m[4], '/', urldecode($m[5]));
                        $status = $file ? 'OK' : 'MISSING';
                        // Check if ctx is hidden
                        if (!$file) {
                            $octx = $DB->get_record('context', array('id' => (int)$m[1]));
                            if ($octx && $octx->contextlevel == 70) {
                                $ocm = $DB->get_record('course_modules', array('id' => $octx->instanceid));
                                $status .= " (ctx belongs to CM $octx->instanceid vis=" . ($ocm ? $ocm->visible : '?') . ")";
                            }
                        }
                    }
                    echo "      IMG: $status -> " . substr($src, 0, 120) . "\n";
                }
            }
        } elseif ($cm->modname == 'page') {
            $mod = $DB->get_record('page', array('id' => $cm->instance));
            $modname = $mod ? $mod->name : '?';
            if ($mod && preg_match_all('#<img[^>]+src=["\']([^"\']+)["\']#', $mod->content, $imgs)) {
                foreach ($imgs[1] as $src) {
                    echo "      IMG: $src\n";
                }
            }
        } elseif ($cm->modname == 'url') {
            $mod = $DB->get_record('url', array('id' => $cm->instance));
            $modname = $mod ? $mod->name : '?';
        } elseif ($cm->modname == 'resource') {
            $mod = $DB->get_record('resource', array('id' => $cm->instance));
            $modname = $mod ? $mod->name : '?';
        } else {
            $modname = '(instance=' . $cm->instance . ')';
        }
        echo "  CM $cmid: $cm->modname vis=$cm->visible ctx=$cm->ctxid -> $modname\n";
    }
}

// 3. Also check course 73 Foundations - find section with Chronic Pain
echo "\n=== Section containing Chronic Pain (CM 2216) in course 73 ===\n";
$section73 = $DB->get_record_sql(
    "SELECT cs.id, cs.section, cs.name, cs.sequence FROM {course_sections} cs
     WHERE cs.course = 73 AND cs.sequence LIKE '%2216%'");
if ($section73) {
    echo "Section $section73->section: $section73->name\n";
    echo "Sequence: $section73->sequence\n\n";
    $cmids = explode(',', $section73->sequence);
    foreach ($cmids as $cmid) {
        $cmid = trim($cmid);
        if (!$cmid) continue;
        $cm = $DB->get_record_sql(
            "SELECT cm.id, cm.visible, m.name as modname, cm.instance
             FROM {course_modules} cm JOIN {modules} m ON m.id = cm.module
             WHERE cm.id = ?", array($cmid));
        if (!$cm) continue;
        $modname = '';
        if ($cm->modname == 'book') {
            $mod = $DB->get_record('book', array('id' => $cm->instance));
            $modname = $mod ? $mod->name : '?';
        } elseif ($cm->modname == 'label') {
            $mod = $DB->get_record('label', array('id' => $cm->instance));
            $modname = $mod ? substr(strip_tags($mod->intro), 0, 60) : '?';
        } else {
            $modname = "(inst=$cm->instance)";
        }
        echo "  CM $cmid: $cm->modname vis=$cm->visible -> $modname\n";
    }
}

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_pain4.php && php /tmp/diag_pain4.php 2>&1 && echo EXIT=0"
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

