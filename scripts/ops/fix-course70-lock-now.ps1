#!/usr/bin/env pwsh
# Emergency fix: "Unable to acquire a lock for caching" on course 70
# Lock key: 70-8f2b746e1ba05fd9f8544d2f64364508
# Root cause: cachestore_file flock() on EFS/NFS is unreliable - lock gets stuck
# Fix: delete stuck lock file + nuke file cache + switch to db_record_lock_factory + restart PHP-FPM
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$Stack   = 'MoodleCdkStack'
)
$ErrorActionPreference = 'Stop'

# Dynamically find the running instance from the CDK stack
Write-Host "Looking up running instance for stack '$Stack'..."
$InstanceId = ((aws --profile $Profile --region $Region ec2 describe-instances `
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" `
            "Name=instance-state-name,Values=running" `
  --query 'Reservations[].Instances[].InstanceId' --output text | Out-String).Trim() -split '\s+')[0]
if (-not $InstanceId) { throw "No running instances found for stack '$Stack'." }
Write-Host "Instance: $InstanceId"

$bash = @'
#!/bin/bash
set -x
LOCK_KEY="70-8f2b746e1ba05fd9f8544d2f64364508"
DATAROOT="/data/moodledata"
CONFIG="/app/moodle/config.php"

echo "=== STEP 1: Find and delete the specific stuck lock file ==="
find "$DATAROOT" -name "*${LOCK_KEY}*" -type f 2>/dev/null | while read f; do
    echo "FOUND: $f"
    rm -f "$f" && echo "  DELETED"
done
echo "Specific lock search done"

echo ""
echo "=== STEP 2: Clear ALL file-based lock directories ==="
rm -rf "$DATAROOT/lock/"* 2>/dev/null && echo "lock/ cleared"
rm -rf "$DATAROOT/temp/lock/"* 2>/dev/null && echo "temp/lock/ cleared"
find "$DATAROOT/cache"      -name "*lock*" -type f -delete 2>/dev/null && echo "cache/ lock files deleted"
find "$DATAROOT/localcache" -name "*lock*" -type f -delete 2>/dev/null && echo "localcache/ lock files deleted"

echo ""
echo "=== STEP 3: Nuke the entire file cache store (will rebuild automatically) ==="
find "$DATAROOT/cache"      -type f -delete 2>/dev/null && echo "cache/ files deleted"
find "$DATAROOT/localcache" -type f -not -path "*/lang/*" -delete 2>/dev/null && echo "localcache/ files deleted (lang preserved)"

echo ""
echo "=== STEP 4: Clear DB lock table ==="
php -r "
define('CLI_SCRIPT', true);
require('$CONFIG');
\$DB->execute('DELETE FROM {lock_db}');
echo 'DB locks cleared: ' . \$DB->count_records('lock_db') . ' remaining' . PHP_EOL;
" 2>&1

echo ""
echo "=== STEP 5: Ensure lock_factory is DB-based (permanent EFS fix) ==="
if grep -q 'lock_factory' "$CONFIG"; then
    echo "lock_factory already in config.php:"
    grep 'lock_factory' "$CONFIG"
else
    php -r "
\$config = file_get_contents('$CONFIG');
\$line = '\$CFG->lock_factory = \"\\\\core\\\\lock\\\\db_record_lock_factory\";' . \"\\n\";
\$config = str_replace(
    'require_once(__DIR__ . \"/lib/setup.php\");',
    \$line . 'require_once(__DIR__ . \"/lib/setup.php\");',
    \$config
);
file_put_contents('$CONFIG', \$config);
echo 'Added db_record_lock_factory to config.php' . PHP_EOL;
" 2>&1
    echo "Verifying:"
    grep 'lock_factory' "$CONFIG"
fi
php -l "$CONFIG" 2>&1 && echo "config.php syntax OK"

echo ""
echo "=== STEP 6: Fix ownership on cache dirs ==="
chown -R apache:apache "$DATAROOT/cache" "$DATAROOT/localcache" "$DATAROOT/lock" "$DATAROOT/temp" 2>/dev/null
chmod 775 "$DATAROOT/cache" "$DATAROOT/localcache" "$DATAROOT/lock" "$DATAROOT/temp" 2>/dev/null
echo "Ownership/permissions fixed"

echo ""
echo "=== STEP 7: Purge Moodle caches via CLI ==="
cd /app/moodle
php admin/cli/purge_caches.php 2>&1
echo "CLI cache purge done"

echo ""
echo "=== STEP 8: Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"

echo ""
echo "=== STEP 9: Verify course 70 is accessible ==="
sleep 3
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 \
    "https://elearning.tsin.ca/course/view.php?id=70" 2>&1

echo ""
echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'fix-course70-lock-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command to $InstanceId ..."
$cmdId = ((aws --profile $Profile --region $Region ssm send-command `
    --instance-ids $InstanceId `
    --document-name AWS-RunShellScript `
    --parameters "file://$paramsFile" `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Write-Host "Waiting 90s for fix to complete..."
Start-Sleep 90

$result = aws --profile $Profile --region $Region --cli-read-timeout 60 ssm get-command-invocation `
    --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

