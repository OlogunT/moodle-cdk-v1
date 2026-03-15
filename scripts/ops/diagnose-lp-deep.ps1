#!/usr/bin/env pwsh
# Deep diagnostic for Learning Programs course editability
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$Stack   = 'MoodleCdkStack'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding           = [System.Text.UTF8Encoding]::new()

$awsArgs = @()
if ($Profile) { $awsArgs += @('--profile', $Profile) }

$instanceId = ((aws @awsArgs ec2 describe-instances --region $Region `
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" `
            "Name=instance-state-name,Values=running" `
  --query 'Reservations[].Instances[].InstanceId' --output text | Out-String).Trim() -split '\s+')[0]
Write-Host "Instance: $instanceId"

$bash = @'
#!/bin/bash
set -euo pipefail
exec > >(LC_ALL=C tr -cd '\11\12\15\40-\176') 2>&1

DB_JSON=$(php -r 'define("CLI_SCRIPT",true); require "/app/moodle/config.php"; echo json_encode(["host"=>$CFG->dbhost,"user"=>$CFG->dbuser,"pass"=>$CFG->dbpass,"name"=>$CFG->dbname]);')
H=$(echo "$DB_JSON" | jq -r .host)
U=$(echo "$DB_JSON" | jq -r .user)
P=$(echo "$DB_JSON" | jq -r .pass)
D=$(echo "$DB_JSON" | jq -r .name)
Q() { mariadb -h "$H" -u "$U" -p"$P" -D "$D" -e "$1" 2>/dev/null || true; }
QN() { mariadb -h "$H" -u "$U" -p"$P" -D "$D" -Nse "$1" 2>/dev/null || true; }

echo "=== Moodle version ==="
QN "SELECT value FROM mdl_config WHERE name='version';"
echo

echo "=== Category 33 visibility chain ==="
Q "SELECT id,name,parent,visible,visibleold FROM mdl_course_categories WHERE id=33 OR id IN (SELECT parent FROM mdl_course_categories WHERE id=33);"
echo

echo "=== Courses in category 33 ==="
Q "SELECT id,shortname,fullname,visible,format,enablecompletion,startdate,enddate FROM mdl_course WHERE category=33 ORDER BY fullname LIMIT 20;"
echo

echo "=== System-level caps: manager/editingteacher for course:update ==="
Q "SELECT r.shortname, rc.capability, rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid JOIN mdl_role r ON r.id=rc.roleid WHERE ctx.contextlevel=10 AND rc.capability LIKE 'moodle/course:%' AND r.shortname IN ('manager','editingteacher','coursecreator') ORDER BY r.shortname, rc.capability;"
echo

echo "=== Role assignments at category 33 context ==="
Q "SELECT r.shortname, u.username, ra.timemodified FROM mdl_role_assignments ra JOIN mdl_role r ON r.id=ra.roleid JOIN mdl_user u ON u.id=ra.userid JOIN mdl_context ctx ON ctx.id=ra.contextid WHERE ctx.contextlevel=40 AND ctx.instanceid=33 ORDER BY r.shortname, u.username LIMIT 20;"
echo

echo "=== CFG settings that restrict course editing ==="
Q "SELECT name,value FROM mdl_config WHERE name IN ('preventcourseupdate','lockoutduration','enablecourserelativedates','coursepublisher') ORDER BY name;"
echo

echo "=== Any capability at category-33 context (ALL caps, not just update) ==="
Q "SELECT r.shortname, rc.capability, rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid JOIN mdl_role r ON r.id=rc.roleid WHERE ctx.contextlevel=40 AND ctx.instanceid=33 ORDER BY r.shortname, rc.capability;"
echo

echo "=== Course publish/lock custom field definitions ==="
Q "SELECT id,shortname,name,type FROM mdl_customfield_field ORDER BY shortname;"
echo

echo "=== check for course_info_data entries for LP courses ==="
Q "SELECT d.instanceid, f.shortname, d.value FROM mdl_customfield_data d JOIN mdl_customfield_field f ON f.id=d.fieldid JOIN mdl_course c ON c.id=d.instanceid WHERE c.category=33 ORDER BY d.instanceid, f.shortname LIMIT 30;"
echo

echo "=== Moodle config: courselifecycle plugin ==="
Q "SELECT plugin,name,value FROM mdl_config_plugins WHERE plugin LIKE '%lifecycle%' OR plugin LIKE '%course_admin%' OR name LIKE '%lock%' OR name LIKE '%freeze%' ORDER BY plugin, name LIMIT 30;"
echo

echo "=== Installed plugins with 'course' in component ==="
Q "SELECT plugin,version FROM mdl_config_plugins WHERE plugin LIKE 'local_%' OR plugin LIKE 'tool_%' ORDER BY plugin LIMIT 30;"
echo

echo "DONE"
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bash))
$tmp = Join-Path $env:TEMP 'diagnose-lp-deep.json'
@{ commands = @(
  "echo '$b64' | base64 -d > /tmp/diag-lp-deep.sh",
  'chmod +x /tmp/diag-lp-deep.sh',
  '/tmp/diag-lp-deep.sh'
) } | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8

Write-Host 'Sending SSM command...'
$cid = ((aws @awsArgs ssm send-command --region $Region `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$tmp" `
  --query 'Command.CommandId' --output text | Out-String).Trim())
Write-Host "CommandId: $cid"

for ($i = 0; $i -lt 75; $i++) {
  Start-Sleep -Seconds 4
  $s = (aws @awsArgs ssm get-command-invocation --region $Region `
    --command-id $cid --instance-id $instanceId `
    --query 'Status' --output text 2>$null | Out-String).Trim()
  Write-Host "[$i] $s"
  if ($s -in 'Success','Failed','Cancelled','TimedOut') { break }
}

$out = aws @awsArgs ssm get-command-invocation --region $Region `
  --command-id $cid --instance-id $instanceId --output json | ConvertFrom-Json
Write-Host '=== STDOUT ==='
Write-Host $out.StandardOutputContent
if ($out.StandardErrorContent) {
  Write-Host '=== STDERR ==='
  Write-Host $out.StandardErrorContent
}

