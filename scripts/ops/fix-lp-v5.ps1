#!/usr/bin/env pwsh
# Diagnose Learning Programs editability - check manager role capabilities & Moodle version
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

echo "=== MOODLE VERSION ==="
$DB -e "SELECT value FROM mdl_config WHERE name='version';" 2>&1

echo "=== MANAGER ROLE: TOTAL CAPABILITY COUNT AT SYSTEM LEVEL ==="
$DB -e "SELECT COUNT(*) AS total_caps,
  SUM(CASE WHEN permission=1 THEN 1 ELSE 0 END) AS allow_count,
  SUM(CASE WHEN permission=-1 THEN 1 ELSE 0 END) AS prevent_count,
  SUM(CASE WHEN permission=-1000 THEN 1 ELSE 0 END) AS prohibit_count
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid AND ctx.contextlevel=10
JOIN mdl_role r ON r.id=rc.roleid AND r.shortname='manager';" 2>&1

echo "=== EDITINGTEACHER ROLE: TOTAL CAPABILITY COUNT AT SYSTEM LEVEL ==="
$DB -e "SELECT COUNT(*) AS total_caps,
  SUM(CASE WHEN permission=1 THEN 1 ELSE 0 END) AS allow_count,
  SUM(CASE WHEN permission=-1 THEN 1 ELSE 0 END) AS prevent_count,
  SUM(CASE WHEN permission=-1000 THEN 1 ELSE 0 END) AS prohibit_count
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid AND ctx.contextlevel=10
JOIN mdl_role r ON r.id=rc.roleid AND r.shortname='editingteacher';" 2>&1

echo "=== KEY COURSE EDITING CAPABILITIES FOR MANAGER ==="
$DB -e "SELECT rc.capability, rc.permission
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid AND ctx.contextlevel=10
JOIN mdl_role r ON r.id=rc.roleid AND r.shortname='manager'
WHERE rc.capability IN (
  'moodle/course:update','moodle/course:manageactivities','moodle/course:activityvisibility',
  'moodle/course:sectionvisibility','moodle/course:movesections','moodle/course:manage',
  'moodle/course:viewhiddensections','moodle/course:setforcedlanguage',
  'moodle/site:accessallgroups','moodle/course:ignoreavailabilityrestrictions'
)
ORDER BY rc.capability;" 2>&1

echo "=== MANAGER CAPABILITIES MISSING VS EDITINGTEACHER ==="
$DB -e "SELECT rc.capability, rc.permission
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid AND ctx.contextlevel=10
JOIN mdl_role r ON r.id=rc.roleid AND r.shortname='editingteacher'
WHERE rc.capability NOT IN (
  SELECT rc2.capability FROM mdl_role_capabilities rc2
  JOIN mdl_context ctx2 ON ctx2.id=rc2.contextid AND ctx2.contextlevel=10
  JOIN mdl_role r2 ON r2.id=rc2.roleid AND r2.shortname='manager'
)
AND rc.capability LIKE 'moodle/course:%'
ORDER BY rc.capability;" 2>&1

echo "=== SITE ADMIN USER IDS ==="
$DB -e "SELECT value FROM mdl_config WHERE name='siteadmins';" 2>&1

echo "=== USERS WITH MANAGER ROLE AT SYSTEM LEVEL ==="
$DB -e "SELECT u.id, u.username, u.firstname, u.lastname
FROM mdl_role_assignments ra
JOIN mdl_context ctx ON ctx.id=ra.contextid AND ctx.contextlevel=10
JOIN mdl_role r ON r.id=ra.roleid AND r.shortname='manager'
JOIN mdl_user u ON u.id=ra.userid
ORDER BY u.username LIMIT 15;" 2>&1

echo "=== CHECK mdl_backup_controllers COLUMNS ==="
$DB -e "DESCRIBE mdl_backup_controllers;" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v5.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v5-params.json'
@{
  commands = @(
    "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v5.sh",
    "chmod +x /tmp/fix-lp-v5.sh",
    "timeout 90 /tmp/fix-lp-v5.sh"
  )
} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" `
  --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

