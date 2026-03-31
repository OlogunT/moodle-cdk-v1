# Fix file-based cache lock for course 70 - find and remove stuck lock files
$shellScript = @'
#!/bin/bash
set -e

echo "=== Finding lock files related to course 70 ==="
find /data/moodledata -name "*70-8f2b746e1ba05fd9f8544d2f64364508*" -type f 2>/dev/null | while read f; do
    echo "FOUND: $f"
    ls -la "$f"
    rm -f "$f"
    echo "  DELETED"
done

echo ""
echo "=== Finding ALL .lock files in moodledata ==="
find /data/moodledata -name "*.lock" -type f 2>/dev/null | head -50 | while read f; do
    echo "LOCK: $f (age: $(( $(date +%s) - $(stat -c %Y "$f") ))s)"
done

echo ""
echo "=== Searching for lock files in cache directories ==="
find /data/moodledata/cache -name "*lock*" -type f 2>/dev/null | while read f; do
    echo "CACHE_LOCK: $f"
    rm -f "$f"
    echo "  DELETED"
done

find /data/moodledata/localcache -name "*lock*" -type f 2>/dev/null | while read f; do
    echo "LOCAL_LOCK: $f"
    rm -f "$f"
    echo "  DELETED"
done

echo ""
echo "=== Listing lock directory ==="
ls -la /data/moodledata/lock/ 2>/dev/null || echo "No lock dir"

echo ""
echo "=== Clearing ALL files from lock directory ==="
rm -rf /data/moodledata/lock/*
echo "Lock dir cleared"

echo ""
echo "=== Finding cachestore_file directories ==="
find /data/moodledata -path "*/cachestore_file*" -type d 2>/dev/null | head -20

echo ""
echo "=== Nuking entire file cache store to force rebuild ==="
# Remove all file cache contents - they will be rebuilt automatically
find /data/moodledata/cache -type f -delete 2>/dev/null
echo "File cache contents deleted"

find /data/moodledata/localcache -type f -not -path "*/lang/*" -delete 2>/dev/null
echo "Local cache contents deleted (preserved lang)"

echo ""
echo "=== Clearing temp lock files ==="
rm -rf /data/moodledata/temp/lock/*
echo "Temp locks cleared"

echo ""
echo "=== Running Moodle cache purge via CLI ==="
cd /app/moodle
php admin/cli/purge_caches.php 2>&1
echo "CLI cache purge done"

echo ""
echo "=== Clearing DB locks again ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$DB->execute('DELETE FROM {lock_db}');
echo 'DB locks cleared: ' . \$DB->count_records('lock_db') . ' remaining\n';
"

echo ""
echo "=== Fixing ownership ==="
chown -R apache:apache /data/moodledata/cache
chown -R apache:apache /data/moodledata/localcache
chown -R apache:apache /data/moodledata/lock
chown -R apache:apache /data/moodledata/temp
echo "Ownership fixed"

echo ""
echo "=== Restarting PHP-FPM and clearing opcache ==="
systemctl restart php-fpm
echo "PHP-FPM restarted"

echo ""
echo "=== Verifying cache dirs exist and are writable ==="
for d in /data/moodledata/cache /data/moodledata/localcache /data/moodledata/lock /data/moodledata/temp/lock; do
    mkdir -p "$d"
    chmod 775 "$d"
    echo "$d: $(stat -c '%U:%G %a' $d) writable=$([ -w $d ] && echo yes || echo no)"
done

echo ""
echo "DONE"
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($shellScript))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_file_cache.sh && chmod +x /tmp/fix_file_cache.sh && bash /tmp/fix_file_cache.sh 2>&1 && echo EXIT=0"
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

