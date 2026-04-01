#!/usr/bin/env pwsh
# Diagnose Learning Programs editability - check category/course level overrides & role assignments
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

echo "=== CONTEXT IDs FOR CAT 33 AND ITS COURSES ==="
$DB -e "SELECT ctx.id AS contextid, ctx.contextlevel, ctx.instanceid,
  CASE ctx.contextlevel WHEN 40 THEN (SELECT name FROM mdl_course_categories WHERE id=ctx.instanceid)
    WHEN 50 THEN (SELECT fullname FROM mdl_course WHERE id=ctx.instanceid) END AS name
FROM mdl_context ctx
WHERE (ctx.contextlevel=40 AND ctx.instanceid=33)
   OR (ctx.contextlevel=50 AND ctx.instanceid IN (SELECT id FROM mdl_course WHERE category=33))
ORDER BY ctx.contextlevel, ctx.instanceid;" 2>&1

echo "=== ROLE CAPABILITY OVERRIDES AT CAT 33 ==="
$DB -e "SELECT r.shortname, rc.capability, rc.permission
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid AND ctx.contextlevel=40 AND ctx.instanceid=33
JOIN mdl_role r ON r.id=rc.roleid
ORDER BY r.shortname, rc.capability;" 2>&1

echo "=== ROLE CAPABILITY OVERRIDES AT COURSE LEVEL (CAT 33 COURSES) ==="
$DB -e "SELECT c.fullname, r.shortname, rc.capability, rc.permission
FROM mdl_role_capabilities rc
JOIN mdl_context ctx ON ctx.id=rc.contextid AND ctx.contextlevel=50
JOIN mdl_course c ON c.id=ctx.instanceid AND c.category=33
JOIN mdl_role r ON r.id=rc.roleid
ORDER BY c.fullname, r.shortname, rc.capability;" 2>&1

echo "=== ROLE ASSIGNMENTS IN CAT 33 COURSES ==="
$DB -e "SELECT c.id AS course_id, LEFT(c.fullname,40) AS course_name,
  r.shortname AS role, COUNT(ra.id) AS assignments
FROM mdl_course c
JOIN mdl_context ctx ON ctx.instanceid=c.id AND ctx.contextlevel=50
JOIN mdl_role_assignments ra ON ra.contextid=ctx.id
JOIN mdl_role r ON r.id=ra.roleid
WHERE c.category=33
GROUP BY c.id, c.fullname, r.shortname
ORDER BY c.fullname, r.shortname;" 2>&1

echo "=== ROLE ASSIGNMENTS AT SYSTEM/CATEGORY LEVEL FOR MANAGER ==="
$DB -e "SELECT ctx.contextlevel, ctx.instanceid, r.shortname,
  (SELECT name FROM mdl_user WHERE id=ra.userid LIMIT 1) AS user_sample
FROM mdl_role_assignments ra
JOIN mdl_context ctx ON ctx.id=ra.contextid
JOIN mdl_role r ON r.id=ra.roleid AND r.shortname='manager'
WHERE ctx.contextlevel IN (10,40)
ORDER BY ctx.contextlevel, ctx.instanceid LIMIT 20;" 2>&1

echo "=== MOODLE SITE CONFIG (relevant settings) ==="
$DB -e "SELECT name, value FROM mdl_config
WHERE name IN ('mnet_dispatcher_mode','auth','enrol_plugins_enabled',
  'enableavailability','enablecompletion','lockconfigifadminediting')
ORDER BY name;" 2>&1

echo "=== CHECK IF COURSES ARE LOCKED (in-progress backup) ==="
$DB -e "SELECT bc.courseid, LEFT(c.fullname,40) AS course_name, bc.status, bc.operation, bc.type
FROM mdl_backup_controllers bc
JOIN mdl_course c ON c.id=bc.courseid
WHERE c.category=33 AND bc.status NOT IN (0, 1000)
ORDER BY bc.courseid;" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v4.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v4-params.json'
@{
  commands = @(
    "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v4.sh",
    "chmod +x /tmp/fix-lp-v4.sh",
    "timeout 90 /tmp/fix-lp-v4.sh"
  )
} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" `
  --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Write-Host "Polling (each AWS call takes ~40s)..."

$done = $false
for ($i = 0; $i -lt 8 -and -not $done; $i++) {
  Start-Sleep 15
  $result = (aws @awsArgs --cli-read-timeout 120 ssm get-command-invocation `
    --command-id $cmdId --instance-id $instanceId --output json 2>&1)
  if ($result -match '"Status"') {
    $parsed = $result | ConvertFrom-Json
    Write-Host "  status=$($parsed.Status)"
    if ($parsed.Status -in 'Success','Failed','Cancelled','TimedOut') {
      Write-Host "=== OUTPUT ==="
      Write-Host $parsed.StandardOutputContent
      if ($parsed.StandardErrorContent) { Write-Host "=== STDERR ==="; Write-Host $parsed.StandardErrorContent }
      $done = $true
    }
  } else {
    Write-Host "  (api call failed or timed out, retrying...)"
  }
}
if (-not $done) { Write-Host "CommandId=$cmdId - check manually" }

