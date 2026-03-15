#!/usr/bin/env pwsh
# Diagnose Learning Programs editability - targeted theme & config check (no log dumps)
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

$bash = @'
#!/bin/bash
CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost); U=$(extract_cfg dbuser); P=$(extract_cfg dbpass); N=$(extract_cfg dbname)
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== ACTIVE THEME ==="
$DB -e "SELECT name, value FROM mdl_config WHERE name='theme';" 2>&1

echo "=== COURSE FORMAT PLUGINS ==="
ls /app/moodle/course/format/ 2>&1

echo "=== MENUTOPIC PLUGIN FILES ==="
ls /app/moodle/course/format/menutopic/ 2>&1

echo "=== COURSE SETTINGS FOR CAT 33 ==="
$DB -e "SELECT id, shortname, format, enablecompletion, lang, theme, visible
FROM mdl_course WHERE category=33 ORDER BY id;" 2>&1

echo "=== COURSE MODULES LOCKED IN CAT 33 (deletioninprogress) ==="
$DB -e "SELECT cm.id, cm.course, cm.module, cm.deletioninprogress, m.name AS module_name
FROM mdl_course_modules cm
JOIN mdl_modules m ON m.id=cm.module
JOIN mdl_course c ON c.id=cm.course AND c.category=33
WHERE cm.deletioninprogress=1;" 2>&1

echo "=== CONFIG.PHP EXTRA SETTINGS ==="
grep -E '^\$CFG->(debug|theme|admin|wwwroot|dataroot|dirroot|prefix|dbtype|passwordsaltmain)' "$CONFIG" 2>&1

echo "=== SITE PROTECTION / LOCK SETTINGS ==="
$DB -e "SELECT name, value FROM mdl_config WHERE name IN (
  'maintenance_enabled','siteprotection','disableuserimages','lockoutthreshold',
  'courseswithsummarieslimit','maxsections','keeptagsinhtmleditor'
) ORDER BY name;" 2>&1

echo "=== CHECK mdl_course_sections FOR CAT 33 COURSES ==="
$DB -e "SELECT c.id, LEFT(c.fullname,30) AS course, COUNT(cs.id) AS sections
FROM mdl_course c
LEFT JOIN mdl_course_sections cs ON cs.course=c.id
WHERE c.category=33 GROUP BY c.id, c.fullname ORDER BY c.id;" 2>&1

echo "=== BACKUP CONTROLLERS FOR CAT 33 (using itemid) ==="
$DB -e "SELECT bc.type, bc.itemid, bc.status, bc.operation,
  (SELECT fullname FROM mdl_course WHERE id=bc.itemid LIMIT 1) AS course_name
FROM mdl_backup_controllers bc
WHERE bc.type='course' AND bc.itemid IN (SELECT id FROM mdl_course WHERE category=33);" 2>&1

echo "=== RECENT PHP ERRORS (last 5 lines from Moodle debug log) ==="
$DB -e "SELECT FROM_UNIXTIME(timecreated) AS ts, userid, ip, component, action, LEFT(info,200) AS info
FROM mdl_logstore_standard_log
WHERE (action LIKE '%error%' OR action LIKE '%fail%')
ORDER BY timecreated DESC LIMIT 10;" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v7.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v7-params.json'
@{
  commands = @(
    "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v7.sh",
    "chmod +x /tmp/fix-lp-v7.sh",
    "timeout 90 /tmp/fix-lp-v7.sh"
  )
} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" `
  --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

