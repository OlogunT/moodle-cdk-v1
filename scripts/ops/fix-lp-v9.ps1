#!/usr/bin/env pwsh
# Fix LP editability:
#   1. Restore menutopic plugin from backup (v5.0.1 is Moodle5-only, incompatible with Moodle 4.5)
#   2. Check capabilities for manager role on courses 111-116 (topics/weeks format)
#   3. Purge Moodle caches
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
#!/bin/bash
set -e
CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost); U=$(extract_cfg dbuser); P=$(extract_cfg dbpass); N=$(extract_cfg dbname)
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== CURRENT MENUTOPIC VERSION IN DB ==="
$DB -e "SELECT plugin,name,value FROM mdl_config_plugins WHERE plugin='format_menutopic';" 2>&1

echo "=== CHECKING BACKUP MENUTOPIC DIR ==="
BAKDIR=$(ls -d /app/moodle/course/format/menutopic.bak.* 2>/dev/null | head -1)
if [ -z "$BAKDIR" ]; then
  echo "ERROR: No backup directory found!"
  exit 1
fi
echo "Backup dir: $BAKDIR"
cat "$BAKDIR/version.php" | grep -E "version|release|requires|supported" 2>&1

echo "=== RESTORING MENUTOPIC FROM BACKUP ==="
cd /app/moodle/course/format
TIMESTAMP=$(date +%s)
mv menutopic menutopic.incompatible.$TIMESTAMP
mv "$BAKDIR" menutopic
echo "Renamed menutopic -> menutopic.incompatible.$TIMESTAMP"
echo "Renamed $BAKDIR -> menutopic"

echo "=== RESTORED MENUTOPIC VERSION ==="
cat /app/moodle/course/format/menutopic/version.php | grep -E "version|release|requires|supported" 2>&1

echo "=== PURGING MOODLE CACHES ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Cache purge done"

echo "=== CHECKING MANAGER ROLE CAPABILITIES FOR CAT 33 ==="
# Get manager roleid
MANAGER_ROLE=$($DB -sN -e "SELECT id FROM mdl_role WHERE shortname='manager';" 2>&1)
echo "Manager role ID: $MANAGER_ROLE"

# Check context for cat 33
CAT33_CTX=$($DB -sN -e "SELECT id FROM mdl_context WHERE contextlevel=40 AND instanceid=33;" 2>&1)
echo "Cat 33 context ID: $CAT33_CTX"

# Check course-level contexts for courses 111-116
echo "Course-level role assignments for manager role on courses 111-116:"
$DB -e "SELECT c.id,c.shortname,ra.userid,ra.contextid
FROM mdl_role_assignments ra
JOIN mdl_context ctx ON ctx.id=ra.contextid AND ctx.contextlevel=50
JOIN mdl_course c ON c.id=ctx.instanceid
WHERE ra.roleid=$MANAGER_ROLE AND c.category=33
ORDER BY c.id;" 2>&1

echo "=== SYSTEM/CATEGORY MANAGER ASSIGNMENTS ==="
$DB -e "SELECT ra.userid,ra.contextid,ctx.contextlevel,ctx.instanceid
FROM mdl_role_assignments ra
JOIN mdl_context ctx ON ctx.id=ra.contextid
WHERE ra.roleid=$MANAGER_ROLE AND ctx.contextlevel IN (10,40)
ORDER BY ctx.contextlevel;" 2>&1

echo "=== moodle/course:update capability for manager ==="
$DB -e "SELECT rc.capability,rc.permission,rc.contextid,ctx.contextlevel
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid
WHERE rc.roleid=$MANAGER_ROLE AND rc.capability='moodle/course:update'
ORDER BY ctx.contextlevel;" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v9.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v9-params.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v9.sh",
  "chmod +x /tmp/fix-lp-v9.sh",
  "timeout 120 /tmp/fix-lp-v9.sh"
)} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 150 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

