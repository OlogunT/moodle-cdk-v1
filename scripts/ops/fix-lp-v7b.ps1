#!/usr/bin/env pwsh
# Diagnose LP editability - hardcoded instance, minimal output
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
#!/bin/bash
CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost); U=$(extract_cfg dbuser); P=$(extract_cfg dbpass); N=$(extract_cfg dbname)
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== THEME ==="
$DB -e "SELECT value FROM mdl_config WHERE name='theme';" 2>&1

echo "=== FORMAT PLUGINS ==="
ls /app/moodle/course/format/ 2>&1

echo "=== COURSE SETTINGS CAT 33 ==="
$DB -e "SELECT id,shortname,format,lang,theme,visible FROM mdl_course WHERE category=33 ORDER BY id;" 2>&1

echo "=== DELETIONINPROGRESS MODULES ==="
$DB -e "SELECT cm.course,cm.id,m.name FROM mdl_course_modules cm JOIN mdl_modules m ON m.id=cm.module JOIN mdl_course c ON c.id=cm.course AND c.category=33 WHERE cm.deletioninprogress=1;" 2>&1

echo "=== BACKUP CONTROLLERS CAT 33 ==="
$DB -e "SELECT type,itemid,status,operation FROM mdl_backup_controllers WHERE type='course' AND itemid IN (SELECT id FROM mdl_course WHERE category=33);" 2>&1

echo "=== CONFIG.PHP WWWROOT ==="
grep -E 'wwwroot|dataroot|dirroot' "$CONFIG" | head -5 2>&1

echo "=== MAINTENANCE ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('maintenance_enabled','siteprotection');" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v7b.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v7b-params.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v7b.sh",
  "chmod +x /tmp/fix-lp-v7b.sh",
  "timeout 60 /tmp/fix-lp-v7b.sh"
)} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 90 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

