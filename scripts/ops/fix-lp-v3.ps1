#!/usr/bin/env pwsh
# Fix Learning Programs editability - v3: grep config.php, no PHP bootstrap
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$Stack   = 'MoodleCdkStack'
)
$ErrorActionPreference = 'Stop'

$awsArgs = @('--profile', $Profile, '--region', $Region)

$instanceId = ((aws @awsArgs ec2 describe-instances `
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" `
            "Name=instance-state-name,Values=running" `
  --query 'Reservations[].Instances[].InstanceId' --output text) -split '\s+')[0].Trim()
Write-Host "Instance: $instanceId"

# Step 1: kill any stuck php/mariadb processes from previous SSM commands, then diagnose + fix
$bash = @'
#!/bin/bash
echo "=== alive $(date) ==="

# Kill stuck PHP processes that may be blocking (from previous SSM commands)
pkill -f "purge_caches" 2>/dev/null || true
pkill -f "admin/cli" 2>/dev/null || true

# Read DB creds from Moodle config.php (format: $CFG->key = 'value';)
CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost)
U=$(extract_cfg dbuser)
P=$(extract_cfg dbpass)
N=$(extract_cfg dbname)
echo "H=$H N=$N"

# Quick connectivity test (5s timeout)
mariadb -h "$H" -u "$U" -p"$P" -D "$N" --connect-timeout=5 -e "SELECT 1 AS ping;" 2>&1
echo "DB OK"

# System-level capabilities for key roles
echo "=== SYSTEM CAPS ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" --connect-timeout=10 -e \
  "SELECT r.shortname, rc.capability, rc.permission
   FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id=rc.contextid
   JOIN mdl_role r ON r.id=rc.roleid
   WHERE ctx.contextlevel=10
   AND rc.capability IN (
     'moodle/course:update','moodle/course:changesummary',
     'moodle/course:visibility','moodle/course:manage'
   )
   ORDER BY r.shortname, rc.capability;" 2>&1

# Count bad overrides
echo "=== PROHIBIT/PREVENT COUNT ==="
CNT=$(mariadb -h "$H" -u "$U" -p"$P" -D "$N" --connect-timeout=10 -Nse \
  "SELECT COUNT(*) FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id=rc.contextid
   WHERE ctx.contextlevel=10
   AND rc.capability IN (
     'moodle/course:update','moodle/course:changesummary',
     'moodle/course:visibility','moodle/course:manage'
   )
   AND rc.permission < 0;" 2>&1)
echo "count=$CNT"

if [ "$CNT" -gt 0 ] 2>/dev/null; then
  echo "=== REMOVING PROHIBIT/PREVENT ==="
  mariadb -h "$H" -u "$U" -p"$P" -D "$N" --connect-timeout=10 -e \
    "DELETE rc FROM mdl_role_capabilities rc
     JOIN mdl_context ctx ON ctx.id=rc.contextid
     WHERE ctx.contextlevel=10
     AND rc.capability IN (
       'moodle/course:update','moodle/course:changesummary',
       'moodle/course:visibility','moodle/course:manage'
     )
     AND rc.permission < 0;" 2>&1
  echo "Deleted $CNT rows"
fi

# Role archetypes
echo "=== ROLE ARCHETYPES ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" --connect-timeout=10 -e \
  "SELECT shortname, name, archetype FROM mdl_role
   WHERE shortname IN ('manager','editingteacher','coursecreator');" 2>&1

# Category + course visibility
echo "=== CAT 33 + COURSES ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" --connect-timeout=10 -e \
  "SELECT c.id, LEFT(c.fullname,50) AS name, c.visible, c.format
   FROM mdl_course c WHERE c.category=33 ORDER BY c.fullname LIMIT 20;" 2>&1

echo "=== DONE ==="
'@

# Write bash to temp file and base64-encode
$bashFile = Join-Path $env:TEMP 'fix-lp-v3.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline

$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

# Write SSM parameters JSON
$paramsFile = Join-Path $env:TEMP 'fix-lp-v3-params.json'
@{
  commands = @(
    "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v3.sh",
    "chmod +x /tmp/fix-lp-v3.sh",
    "timeout 60 /tmp/fix-lp-v3.sh"
  )
} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" `
  --timeout-seconds 90 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

# Poll for up to 100 seconds
$deadline = (Get-Date).AddSeconds(100)
$lastStatus = ''
while ((Get-Date) -lt $deadline) {
  Start-Sleep 6
  $st = ((aws @awsArgs ssm get-command-invocation `
    --command-id $cmdId --instance-id $instanceId `
    --query 'Status' --output text 2>$null)).Trim()
  if ($st -ne $lastStatus) { Write-Host "  status=$st"; $lastStatus = $st }
  if ($st -in 'Success','Failed','Cancelled','TimedOut') { break }
}

Write-Host "=== FINAL RESULT ==="
aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $instanceId `
  --query '{Status:Status,RC:ResponseCode,Out:StandardOutputContent,Err:StandardErrorContent}' `
  --output json

