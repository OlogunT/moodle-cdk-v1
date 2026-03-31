# Fix cachestore_file lock issue - switch lock factory to DB-based
$shellScript = @'
#!/bin/bash
set -x

# 1. Clear all DB locks
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$DB->execute('DELETE FROM {lock_db}');
echo 'DB locks cleared\n';
purge_all_caches();
echo 'Caches purged\n';
"

# 2. Clear file-based locks and cache
rm -rf /data/moodledata/lock/* 2>/dev/null
rm -rf /data/moodledata/temp/lock/* 2>/dev/null
echo "Lock files cleared"

# 3. Check if lock_factory is already in config.php
echo "=== Current config.php lock settings ==="
grep -n 'lock_factory\|cachelock' /app/moodle/config.php 2>/dev/null || echo "No lock_factory setting found"

# 4. Add lock_factory to use DB-based locks instead of file locks (EFS-safe)
if ! grep -q 'lock_factory' /app/moodle/config.php; then
    # Insert before the require_once setup.php line
    php -r "
\$config = file_get_contents('/app/moodle/config.php');
\$line = '\\\$CFG->lock_factory = \"\\\\core\\\\lock\\\\db_record_lock_factory\";' . \"\\n\";
\$config = str_replace(
    'require_once(__DIR__ . \"/lib/setup.php\");',
    \$line . 'require_once(__DIR__ . \"/lib/setup.php\");',
    \$config
);
file_put_contents('/app/moodle/config.php', \$config);
echo 'Added db_record_lock_factory to config.php\n';
"
else
    echo "lock_factory already configured"
fi

# 5. Verify the change
echo "=== Updated config.php lock settings ==="
grep -n 'lock_factory' /app/moodle/config.php

# 6. Purge caches via CLI
cd /app/moodle
php admin/cli/purge_caches.php 2>&1
echo "CLI caches purged"

# 7. Restart PHP-FPM
systemctl restart php-fpm
echo "PHP-FPM restarted"

echo "DONE"
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($shellScript))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_lock_factory.sh && chmod +x /tmp/fix_lock_factory.sh && bash /tmp/fix_lock_factory.sh 2>&1 && echo EXIT=0"
$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 60
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

