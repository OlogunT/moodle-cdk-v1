# Check context ID mismatch - URL uses 16799 but file may be at different context
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. What is context 16799? ===\n";
$ctx = $DB->get_record('context', array('id' => 16799));
if ($ctx) {
    $levels = [10=>'System',30=>'User',40=>'Category',50=>'Course',70=>'Module',80=>'Block'];
    echo "Context 16799: level=" . ($levels[$ctx->contextlevel] ?? $ctx->contextlevel) . " instanceid=$ctx->instanceid\n";
    if ($ctx->contextlevel == 70) {
        $cm = $DB->get_record('course_modules', array('id' => $ctx->instanceid));
        if ($cm) {
            $mod = $DB->get_field('modules', 'name', array('id' => $cm->module));
            echo "  Module: $mod, instance=$cm->instance, course=$cm->course, visible=$cm->visible\n";
        } else {
            echo "  CM $ctx->instanceid NOT FOUND - orphaned context!\n";
        }
    }
} else {
    echo "Context 16799 DOES NOT EXIST!\n";
}

echo "\n=== 2. What is context for CM 3852? ===\n";
$cmctx = $DB->get_record('context', array('contextlevel' => 70, 'instanceid' => 3852));
if ($cmctx) {
    echo "CM 3852 context id: $cmctx->id\n";
} else {
    echo "No context found for CM 3852!\n";
}

echo "\n=== 3. Files at context 16799 ===\n";
$files16799 = $DB->get_records_sql(
    "SELECT id, component, filearea, itemid, filename, filesize FROM {files}
     WHERE contextid = 16799 AND filename != '.' AND filesize > 0 LIMIT 10");
echo count($files16799) . " files at context 16799\n";
foreach ($files16799 as $f) {
    echo "  $f->component/$f->filearea item=$f->itemid: $f->filename ($f->filesize)\n";
}

echo "\n=== 4. Files for book chapter 840 (any context) ===\n";
$ch840 = $DB->get_records_sql(
    "SELECT id, contextid, component, filearea, itemid, filename, filesize, contenthash FROM {files}
     WHERE component = 'mod_book' AND filearea = 'chapter' AND itemid = 840
     AND filename != '.' AND filesize > 0");
echo count($ch840) . " files for chapter 840\n";
foreach ($ch840 as $f) {
    echo "  ctx=$f->contextid: $f->filename ($f->filesize) hash=$f->contenthash\n";
    $dir1 = substr($f->contenthash, 0, 2);
    $dir2 = substr($f->contenthash, 2, 2);
    $path = "/data/moodledata/filedir/$dir1/$dir2/$f->contenthash";
    echo "    disk: " . (file_exists($path) ? "EXISTS" : "MISSING!") . " $path\n";
}

echo "\n=== 5. Book chapter 840 details ===\n";
$chapter = $DB->get_record('book_chapters', array('id' => 840));
if ($chapter) {
    echo "Chapter: bookid=$chapter->bookid title=$chapter->title hidden=$chapter->hidden\n";
    $book = $DB->get_record('book', array('id' => $chapter->bookid));
    echo "Book: id=$book->id name=$book->name course=$book->course\n";
    $bookmod = $DB->get_field('modules', 'id', array('name' => 'book'));
    $bookcm = $DB->get_record('course_modules', array('instance' => $book->id, 'module' => $bookmod, 'course' => $book->course));
    if ($bookcm) {
        echo "Book CM: id=$bookcm->id\n";
        $bookctx = $DB->get_record('context', array('contextlevel' => 70, 'instanceid' => $bookcm->id));
        echo "Book context: id=" . ($bookctx ? $bookctx->id : 'NOT FOUND') . "\n";
        echo "URL should use context: " . ($bookctx ? $bookctx->id : '???') . "\n";
        echo "URL is using context: 16799\n";
        if ($bookctx && $bookctx->id != 16799) {
            echo "*** CONTEXT MISMATCH! URL uses 16799 but correct context is $bookctx->id ***\n";
        }
    }
}

echo "\n=== 6. Simulate pluginfile access ===\n";
// The URL: /pluginfile.php/16799/mod_book/chapter/840/Curricular%20Advisory%20Committee.png
// pluginfile.php parses: contextid=16799, component=mod_book, filearea=chapter, itemid=840, filename=...
// It then calls get_file_storage()->get_file() with those params
$fs = get_file_storage();
$file = $fs->get_file(16799, 'mod_book', 'chapter', 840, '/', 'Curricular Advisory Committee.png');
if ($file) {
    echo "File found via API at context 16799: YES\n";
    echo "  size: " . $file->get_filesize() . "\n";
} else {
    echo "File NOT found at context 16799 - this causes the 303!\n";
    // Try correct context
    if (isset($bookctx) && $bookctx) {
        $file2 = $fs->get_file($bookctx->id, 'mod_book', 'chapter', 840, '/', 'Curricular Advisory Committee.png');
        if ($file2) {
            echo "File FOUND at correct context $bookctx->id\n";
            echo "  size: " . $file2->get_filesize() . "\n";
        }
    }
}

echo "\n=== 7. Check if context 16799 is from an old/different CM ===\n";
if ($ctx && $ctx->contextlevel == 70 && $ctx->instanceid != 3852) {
    echo "Context 16799 belongs to CM $ctx->instanceid, NOT CM 3852\n";
    $oldcm = $DB->get_record('course_modules', array('id' => $ctx->instanceid));
    if ($oldcm) {
        $oldmod = $DB->get_field('modules', 'name', array('id' => $oldcm->module));
        echo "  Old CM: module=$oldmod instance=$oldcm->instance course=$oldcm->course\n";
    }
}

echo "\n=== 8. Test with curl as student ===\n";
$url = $CFG->wwwroot . '/pluginfile.php/16799/mod_book/chapter/840/Curricular%20Advisory%20Committee.png';
echo "URL: $url\n";

echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/diag_ctx.php && php /tmp/diag_ctx.php 2>&1 && echo EXIT=0"

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

