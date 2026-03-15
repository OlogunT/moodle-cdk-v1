#!/usr/bin/env pwsh
# Verify menutopic restore, purge caches, and check course 111-116 editability
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
#!/bin/bash
# Write all output to both stdout and a temp file to ensure capture
OUTFILE=/tmp/v10-output.txt
exec > >(tee -a "$OUTFILE") 2>&1

CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost); U=$(extract_cfg dbuser); P=$(extract_cfg dbpass); N=$(extract_cfg dbname)
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== CURRENT MENUTOPIC FORMAT DIR ==="
ls /app/moodle/course/format/ | grep -i menu

echo "=== CURRENT MENUTOPIC VERSION.PHP ==="
grep -E "version|release|requires|supported" /app/moodle/course/format/menutopic/version.php 2>&1 || echo "NOT FOUND"

echo "=== FORMAT DIRS WITH menutopic IN NAME ==="
ls -d /app/moodle/course/format/menutopic* 2>/dev/null || echo "none"

echo "=== CHECKING IF INCOMPATIBLE DIR EXISTS ==="
ls -d /app/moodle/course/format/menutopic.incompatible.* 2>/dev/null && echo "Incompatible dir exists - v9 ran successfully" || echo "No incompatible dir - v9 may not have run the mv"

echo "=== IF INCOMPATIBLE EXISTS, VERIFY ITS VERSION ==="
INCOMP=$(ls -d /app/moodle/course/format/menutopic.incompatible.* 2>/dev/null | head -1)
if [ -n "$INCOMP" ]; then
  echo "Incompatible dir: $INCOMP"
  grep -E "version|release|supported" "$INCOMP/version.php" 2>&1 || true
fi

echo "=== IF NOT RESTORED YET, DO IT NOW ==="
CURRENT_VER=$(grep -m1 'release' /app/moodle/course/format/menutopic/version.php 2>/dev/null | grep -o "'[^']*'" | tr -d "'" || echo "unknown")
echo "Current menutopic release: $CURRENT_VER"

if echo "$CURRENT_VER" | grep -q "5.0"; then
  echo "MENUTOPIC IS STILL MOODLE 5.0 VERSION - NEED TO RESTORE BACKUP"
  BAKDIR=$(ls -d /app/moodle/course/format/menutopic.bak.* 2>/dev/null | head -1)
  if [ -n "$BAKDIR" ]; then
    echo "Found backup: $BAKDIR"
    TIMESTAMP=$(date +%s)
    mv /app/moodle/course/format/menutopic /app/moodle/course/format/menutopic.incompatible.$TIMESTAMP
    mv "$BAKDIR" /app/moodle/course/format/menutopic
    echo "RESTORED: menutopic from $BAKDIR"
    grep -E "version|release|supported" /app/moodle/course/format/menutopic/version.php 2>&1 || true
  else
    echo "ERROR: No backup dir available! Listing all format dirs:"
    ls /app/moodle/course/format/
  fi
else
  echo "menutopic appears to be a compatible version already"
fi

echo "=== PURGING MOODLE CACHES (background) ==="
nohup php /app/moodle/admin/cli/purge_caches.php > /tmp/purge_caches.log 2>&1 &
PURGE_PID=$!
echo "Cache purge PID: $PURGE_PID"
sleep 5
if kill -0 $PURGE_PID 2>/dev/null; then
  echo "Cache purge still running after 5s (that's OK, it's in background)"
else
  echo "Cache purge completed quickly"
  cat /tmp/purge_caches.log 2>/dev/null || true
fi

echo "=== MOODLE DB PLUGIN VERSION FOR MENUTOPIC ==="
$DB -e "SELECT plugin,name,value FROM mdl_config_plugins WHERE plugin='format_menutopic' ORDER BY name;" 2>&1

echo "=== MANAGER ROLE ID ==="
MANAGER_ROLE=$($DB -sN -e "SELECT id FROM mdl_role WHERE shortname='manager';" 2>&1)
echo "Manager role ID: $MANAGER_ROLE"

echo "=== ROLE ASSIGNMENTS FOR CAT 33 COURSES ==="
$DB -e "SELECT c.id,c.shortname,c.format,ra.userid,ctx.contextlevel
FROM mdl_role_assignments ra
JOIN mdl_context ctx ON ctx.id=ra.contextid
JOIN mdl_course c ON (ctx.contextlevel=50 AND c.id=ctx.instanceid)
WHERE ra.roleid=$MANAGER_ROLE AND c.category=33
ORDER BY c.id;" 2>&1

echo "=== DONE ==="
cat "$OUTFILE" 2>/dev/null | wc -l
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v10.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v10-params.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v10.sh",
  "chmod +x /tmp/fix-lp-v10.sh",
  "timeout 90 /tmp/fix-lp-v10.sh; cat /tmp/v10-output.txt 2>/dev/null"
)} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

