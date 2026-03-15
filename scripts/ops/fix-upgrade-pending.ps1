#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
set -e
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== STEP 1: Kill ALL stuck cron.php processes ==="
pkill -9 -f "cron.php" 2>&1 && echo "Killed cron.php" || echo "No cron to kill"
sleep 2

echo "=== STEP 2: Disable cron temporarily ==="
# Comment out the cron entry
crontab -u apache -l 2>/dev/null > /tmp/apache-crontab-backup.txt || true
echo "Current crontab:"
cat /tmp/apache-crontab-backup.txt
crontab -u apache -l 2>/dev/null | sed 's|^\(.*/cron.php.*\)|#DISABLED# \1|' | crontab -u apache - 2>&1 || echo "Could not modify crontab"
echo "Modified crontab:"
crontab -u apache -l 2>/dev/null || echo "No crontab"

echo "=== STEP 3: Clear upgrade lock ==="
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1
echo "Cleared"

echo "=== STEP 4: Clear allversionshash to force recalc ==="
$DB -e "DELETE FROM mdl_config WHERE name='allversionshash';" 2>&1
echo "Cleared hash"

echo "=== STEP 5: Restart PHP-FPM to free workers ==="
systemctl restart php-fpm 2>&1
sleep 3
echo "PHP-FPM restarted"

echo "=== STEP 6: Run upgrade.php ==="
timeout 120 php /app/moodle/admin/cli/upgrade.php --non-interactive 2>&1
UPGRADE_EXIT=$?
echo "Upgrade exit: $UPGRADE_EXIT"

echo "=== STEP 7: Purge caches ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Purge exit: $?"

echo "=== STEP 8: Re-enable cron ==="
if [ -f /tmp/apache-crontab-backup.txt ]; then
  crontab -u apache /tmp/apache-crontab-backup.txt 2>&1
  echo "Cron restored"
fi

echo "=== STEP 9: Test login page speed ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 https://elearning.tsin.ca/login/index.php 2>&1

echo "=== STEP 10: Verify DB state ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'fix-upgrade-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 300 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Write-Host "Waiting 180s for completion..."
Start-Sleep 180
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

