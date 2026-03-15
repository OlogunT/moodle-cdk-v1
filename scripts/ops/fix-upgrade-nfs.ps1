#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
echo "=== Step 1: Kill stuck processes ==="
pkill -9 -f "upgrade.php" 2>/dev/null; echo "upgrade killed: $?"
pkill -9 -f "cron.php" 2>/dev/null; echo "cron killed: $?"
sleep 2

echo "=== Step 2: Disable cron ==="
crontab -u apache -r 2>/dev/null || true
echo "Cron disabled"

echo "=== Step 3: Clear DB locks ==="
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1

echo "=== Step 4: Pre-warm NFS cache (read all version.php files) ==="
time find /app/moodle -name "version.php" -exec cat {} + > /dev/null 2>&1
echo "Warm-up done, exit: $?"

echo "=== Step 5: Pre-warm all PHP files in key directories ==="
time find /app/moodle/lib -name "*.php" -exec cat {} + > /dev/null 2>&1
echo "Lib warm-up done"

echo "=== Step 6: Verify no D-state processes ==="
ps aux | awk '$8 ~ /D/ {print}' || echo "No D-state"

echo "=== Step 7: Start upgrade with nohup ==="
nohup php /app/moodle/admin/cli/upgrade.php --non-interactive > /tmp/upgrade-log.txt 2>&1 &
UPID=$!
echo "Upgrade PID: $UPID"

echo "=== Step 8: Monitor for 30s ==="
for i in $(seq 1 6); do
  sleep 5
  STATE=$(cat /proc/$UPID/status 2>/dev/null | grep State | awk '{print $2}')
  SIZE=$(stat -c%s /tmp/upgrade-log.txt 2>/dev/null || echo 0)
  echo "  ${i}0s: state=$STATE logsize=$SIZE"
done

echo "=== Step 9: Log contents so far ==="
tail -30 /tmp/upgrade-log.txt 2>/dev/null || echo "No log"

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'fix-upgrade-nfs-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Write-Host "Waiting 100s..."
Start-Sleep 100
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

