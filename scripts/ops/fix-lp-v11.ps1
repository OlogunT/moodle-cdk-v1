#!/usr/bin/env pwsh
# Update menutopic DB version to match restored filesystem version, then run upgrade
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
#!/bin/bash
OUTFILE=/tmp/v11-output.txt
CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost); U=$(extract_cfg dbuser); P=$(extract_cfg dbpass); N=$(extract_cfg dbname)
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

{
echo "=== CURRENT MENUTOPIC VERSION ON DISK ==="
DISK_VER=$(grep -m1 '\$plugin->version' /app/moodle/course/format/menutopic/version.php | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "Disk version: $DISK_VER"

echo "=== CURRENT MENUTOPIC VERSION IN DB ==="
DB_VER=$($DB -sN -e "SELECT value FROM mdl_config_plugins WHERE plugin='format_menutopic' AND name='version';" 2>&1)
echo "DB version: $DB_VER"

echo "=== UPDATING DB VERSION TO MATCH DISK ==="
# Set version to 2023050703 (integer part of 2023050703.01)
$DB -e "UPDATE mdl_config_plugins SET value='2023050703' WHERE plugin='format_menutopic' AND name='version';" 2>&1
echo "Update done"

echo "=== VERIFYING DB UPDATE ==="
$DB -e "SELECT plugin,name,value FROM mdl_config_plugins WHERE plugin='format_menutopic' AND name='version';" 2>&1

echo "=== RUNNING MOODLE UPGRADE CLI ==="
php /app/moodle/admin/cli/upgrade.php --non-interactive 2>&1
echo "Upgrade CLI exit code: $?"

echo "=== RUNNING MOODLE ADMIN NOTIFICATIONS CHECK ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Cache purge exit code: $?"

echo "=== VERIFYING MENUTOPIC ON DISK ==="
grep -E "version|release|requires" /app/moodle/course/format/menutopic/version.php 2>&1

echo "=== MOODLE SITE CONFIG CHECK ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('dbversion','version','release') ORDER BY name;" 2>&1

echo "=== DONE ==="
} | tee "$OUTFILE"
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v11.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v11-params.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v11.sh",
  "chmod +x /tmp/fix-lp-v11.sh",
  "timeout 150 bash /tmp/fix-lp-v11.sh; echo EXIT:$?; cat /tmp/v11-output.txt 2>/dev/null | tail -5"
)} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 180 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

