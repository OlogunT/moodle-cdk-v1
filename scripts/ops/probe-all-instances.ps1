#!/usr/bin/env pwsh
# Send a combined probe+fix to all candidate instances at once
# The script checks if Moodle is installed, and if so applies the nuclear fix
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1'
)

$bash = @'
#!/bin/bash
INST=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)
if [ ! -f /app/moodle/config.php ]; then
  echo "NOT_MOODLE $INST - skipping"
  exit 0
fi
echo "MOODLE_FOUND $INST - applying fix"

# Kill stuck processes
pkill -9 -u apache 2>/dev/null; pkill -9 -f "php" 2>/dev/null; pkill -9 -f "find /data" 2>/dev/null
sleep 1

# Fix config.php
php -l /app/moodle/config.php 2>&1
if ! grep -q "lock_factory" /app/moodle/config.php; then
  sed -i "s|require_once(__DIR__ . '/lib/setup.php');|\$CFG->lock_factory = 'core\\lock\\db_record_lock_factory';\nrequire_once(__DIR__ . '/lib/setup.php');|" /app/moodle/config.php
  echo "lock_factory added"
fi
grep -n "lock_factory" /app/moodle/config.php

# Clear lock dirs
rm -f /data/moodledata/lock/* 2>/dev/null; echo "locks cleared"

# Restart services
systemctl restart php-fpm 2>&1 && echo "php-fpm OK"
systemctl restart httpd 2>&1 && echo "httpd OK"
sleep 3
curl -s -o /dev/null -w "local_HTTP:%{http_code}" --max-time 5 http://localhost/ 2>&1
echo ""
echo "FIX_DONE $INST"
'@

$pf = Join-Path $env:TEMP 'probe-fix.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8

$candidates = @(
  'i-0527f81ac3fde0ec3','i-076b687e9bf43a1a4','i-0ac15d6e22f204649',
  'i-0dca2f988e797653f','i-005355f82b1206aff','i-0f3e2ff1be8ff986a',
  'i-0080670f33aeddd08','i-04ee31773fdaa5a5c','i-03c8a62253d2a10a4',
  'i-0bdae18253da2e0c4','i-09c83f782d36e0f40','i-0a7ec1da61c80bdeb'
)

Write-Host "Sending probe+fix to $($candidates.Count) candidate instances..."
$cmdId = (aws --profile $Profile --region $Region ssm send-command `
    --instance-ids @candidates `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
Write-Host "Probe CMD: $cmdId"
$cmdId | Set-Content (Join-Path $env:TEMP 'probe-cmd-id.txt')
Write-Host "Saved to probe-cmd-id.txt. Now run poll-probe-results.ps1 after 40 seconds."

