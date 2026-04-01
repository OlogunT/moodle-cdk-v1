#!/usr/bin/env pwsh
# Fix system-level role capability overrides blocking Learning Programs course editing (v2 - no process substitution)
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$Stack   = 'MoodleCdkStack'
)
$ErrorActionPreference = 'Stop'

$script:awsArgs = @('--profile', $Profile)
$instanceId = ((aws @awsArgs ec2 describe-instances --region $Region `
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" `
            "Name=instance-state-name,Values=running" `
  --query 'Reservations[].Instances[].InstanceId' --output text | Out-String).Trim() -split '\s+')[0]
Write-Host "Instance: $instanceId"

# Simple bash - no exec redirection, no sudo, no cache purge (to avoid hangs)
$bash = @'
#!/bin/bash
set -e
DB_JSON=$(php -r 'define("CLI_SCRIPT",true); require "/app/moodle/config.php"; echo json_encode(["h"=>$CFG->dbhost,"u"=>$CFG->dbuser,"p"=>$CFG->dbpass,"n"=>$CFG->dbname]);')
H=$(echo "$DB_JSON" | jq -r .h)
U=$(echo "$DB_JSON" | jq -r .u)
P=$(echo "$DB_JSON" | jq -r .p)
N=$(echo "$DB_JSON" | jq -r .n)
CAPS="'moodle/course:update','moodle/course:changesummary','moodle/course:visibility','moodle/course:manage','moodle/course:create'"
echo "=== SYSTEM-LEVEL CAPS (contextlevel=10) ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e "SELECT r.shortname, rc.capability, rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid JOIN mdl_role r ON r.id=rc.roleid WHERE ctx.contextlevel=10 AND rc.capability IN ($CAPS) ORDER BY r.shortname, rc.capability;" 2>&1
echo "=== MANAGER + EDITINGTEACHER ARCHETYPES ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e "SELECT shortname, name, archetype FROM mdl_role WHERE shortname IN ('manager','editingteacher','coursecreator');" 2>&1
echo "=== COUNT PROHIBIT/PREVENT AT SYSTEM LEVEL ==="
CNT=$(mariadb -h "$H" -u "$U" -p"$P" -D "$N" -Nse "SELECT COUNT(*) FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid WHERE ctx.contextlevel=10 AND rc.capability IN ($CAPS) AND rc.permission < 0;")
echo "Prohibit/Prevent count: $CNT"
if [ "$CNT" -gt 0 ]; then
  echo "=== REMOVING SYSTEM-LEVEL PROHIBIT/PREVENT ==="
  mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e "DELETE rc FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid WHERE ctx.contextlevel=10 AND rc.capability IN ($CAPS) AND rc.permission < 0;" 2>&1
  echo "Removed $CNT row(s). Purging caches..."
  php /app/moodle/admin/cli/purge_caches.php 2>&1
else
  echo "No system-level prohibit/prevent found."
fi
echo "=== SITE MAINTENANCE MODE ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -Nse "SELECT name, value FROM mdl_config WHERE name IN ('maintenance_enabled','auth_twofactorauthentication');" 2>&1
echo "=== DONE ==="
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bash))
$tmp = Join-Path $env:TEMP 'fix-lp-syscaps-v2.json'
@{ commands = @(
  "echo '$b64' | base64 -d > /tmp/fix-lp-v2.sh",
  'chmod +x /tmp/fix-lp-v2.sh',
  '/tmp/fix-lp-v2.sh'
) } | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8

Write-Host 'Sending SSM command...'
$cmdId = ((aws @awsArgs ssm send-command --region $Region `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$tmp" `
  --query 'Command.CommandId' --output text | Out-String).Trim())
Write-Host "CommandId: $cmdId"

$deadline = (Get-Date).AddSeconds(120)
do {
  Start-Sleep 5
  $st = (aws @awsArgs ssm get-command-invocation --region $Region `
    --command-id $cmdId --instance-id $instanceId `
    --query 'Status' --output text 2>$null | Out-String).Trim()
  Write-Host "  status=$st"
  if ($st -in 'Success','Failed','Cancelled','TimedOut') { break }
} while ((Get-Date) -lt $deadline)

$r = (aws @awsArgs ssm get-command-invocation --region $Region `
  --command-id $cmdId --instance-id $instanceId --output json | ConvertFrom-Json)
Write-Host "=== STDOUT ==="
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "=== STDERR ==="; Write-Host $r.StandardErrorContent }

