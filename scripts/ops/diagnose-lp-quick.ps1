#!/usr/bin/env pwsh
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
exec 2>&1
H=$(php -r 'define("CLI_SCRIPT",true);require"/app/moodle/config.php";echo $CFG->dbhost;')
U=$(php -r 'define("CLI_SCRIPT",true);require"/app/moodle/config.php";echo $CFG->dbuser;')
P=$(php -r 'define("CLI_SCRIPT",true);require"/app/moodle/config.php";echo $CFG->dbpass;')
D=$(php -r 'define("CLI_SCRIPT",true);require"/app/moodle/config.php";echo $CFG->dbname;')
Q(){ mariadb -h "$H" -u "$U" -p"$P" -D "$D" -e "$1" 2>/dev/null||true; }
echo "=== Version ===" && Q "SELECT value FROM mdl_config WHERE name='version';"
echo "=== Cat33 ===" && Q "SELECT id,name,visible,visibleold FROM mdl_course_categories WHERE id=33;"
echo "=== LP Courses ===" && Q "SELECT id,shortname,visible,format FROM mdl_course WHERE category=33 ORDER BY id LIMIT 10;"
echo "=== System caps manager ===" && Q "SELECT r.shortname,rc.capability,rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid JOIN mdl_role r ON r.id=rc.roleid WHERE ctx.contextlevel=10 AND rc.capability LIKE 'moodle/course:update' ORDER BY r.shortname;"
echo "=== Cat33 role caps (ALL) ===" && Q "SELECT r.shortname,rc.capability,rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid JOIN mdl_role r ON r.id=rc.roleid WHERE ctx.contextlevel=40 AND ctx.instanceid=33 ORDER BY r.shortname,rc.capability;"
echo "=== Cat33 role assignments ===" && Q "SELECT r.shortname,u.username FROM mdl_role_assignments ra JOIN mdl_role r ON r.id=ra.roleid JOIN mdl_user u ON u.id=ra.userid JOIN mdl_context ctx ON ctx.id=ra.contextid WHERE ctx.contextlevel=40 AND ctx.instanceid=33 LIMIT 20;"
echo "=== CFG restrict ===" && Q "SELECT name,value FROM mdl_config WHERE name IN('preventcourseupdate','coursepublisher','enablecourselifecycle','disableuserimages') ORDER BY name;"
echo "=== local plugins installed ===" && Q "SELECT plugin FROM mdl_config_plugins WHERE plugin LIKE 'local_%' GROUP BY plugin ORDER BY plugin;"
echo "=== tool plugins installed ===" && Q "SELECT plugin FROM mdl_config_plugins WHERE plugin LIKE 'tool_%' GROUP BY plugin ORDER BY plugin LIMIT 20;"
echo "=== customfield defs ===" && Q "SELECT id,shortname,name FROM mdl_customfield_field ORDER BY shortname LIMIT 20;"
echo "DONE"
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bash))
$tmp = Join-Path $env:TEMP 'diagnose-lp-quick.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/dlpq.sh",
  'chmod +x /tmp/dlpq.sh',
  '/tmp/dlpq.sh'
); executionTimeout = @('120') } | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8

Write-Host 'Sending SSM command...'
$cid = ((aws @awsArgs ssm send-command --region $Region `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$tmp" `
  --query 'Command.CommandId' --output text | Out-String).Trim())
Write-Host "CommandId: $cid"

for ($i = 0; $i -lt 40; $i++) {
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
if ($out.StandardErrorContent) { Write-Host '=== STDERR ==='; Write-Host $out.StandardErrorContent }

