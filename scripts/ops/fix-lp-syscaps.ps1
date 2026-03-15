#!/usr/bin/env pwsh
# Fix system-level role capability overrides blocking Learning Programs course editing
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$Stack   = 'MoodleCdkStack'
)
$ErrorActionPreference = 'Stop'

# Get instance ID
$script:awsArgs = @('--profile', $Profile)
$instanceId = ((aws @awsArgs ec2 describe-instances --region $Region `
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" `
            "Name=instance-state-name,Values=running" `
  --query 'Reservations[].Instances[].InstanceId' --output text | Out-String).Trim() -split '\s+')[0]
Write-Host "Instance: $instanceId"

$bash = @'
#!/bin/bash
exec > >(LC_ALL=C tr -cd '\11\12\15\40-\176') 2>&1
DB_JSON=$(php -r 'define("CLI_SCRIPT",true); require "/app/moodle/config.php"; echo json_encode(["h"=>$CFG->dbhost,"u"=>$CFG->dbuser,"p"=>$CFG->dbpass,"n"=>$CFG->dbname]);')
H=$(echo "$DB_JSON" | jq -r .h)
U=$(echo "$DB_JSON" | jq -r .u)
P=$(echo "$DB_JSON" | jq -r .p)
N=$(echo "$DB_JSON" | jq -r .n)
CAPS="'moodle/course:update','moodle/course:changesummary','moodle/course:visibility','moodle/course:manage','moodle/course:create'"
echo "=== SYSTEM-LEVEL (contextlevel=10) CAPABILITY OVERRIDES FOR EDITING CAPS ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e \
  "SELECT r.shortname, rc.capability, rc.permission FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id=rc.contextid JOIN mdl_role r ON r.id=rc.roleid
   WHERE ctx.contextlevel=10 AND rc.capability IN ($CAPS) ORDER BY r.shortname, rc.capability;"
echo ""
echo "=== MANAGER ROLE DEFAULT CAPS FOR COURSE:UPDATE ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e \
  "SELECT r.shortname, r.id FROM mdl_role r WHERE r.shortname IN ('manager','editingteacher','coursecreator');"
echo ""
echo "=== COUNT OF PROHIBIT/PREVENT OVERRIDES AT SYSTEM LEVEL ==="
CNT=$(mariadb -h "$H" -u "$U" -p"$P" -D "$N" -Nse \
  "SELECT COUNT(*) FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid
   WHERE ctx.contextlevel=10 AND rc.capability IN ($CAPS) AND rc.permission < 0;")
echo "Count: $CNT"
if [ "$CNT" -gt 0 ]; then
  echo "=== FIXING: Removing system-level PROHIBIT/PREVENT overrides ==="
  mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e \
    "DELETE rc FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id=rc.contextid
     WHERE ctx.contextlevel=10 AND rc.capability IN ($CAPS) AND rc.permission < 0;"
  echo "Removed $CNT row(s)."
fi
echo ""
echo "=== SITE MAINTENANCE MODE ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -Nse \
  "SELECT value FROM mdl_config WHERE name='maintenance_enabled';"
echo ""
echo "=== MANAGER ROLE ARCHETYPE ==="
mariadb -h "$H" -u "$U" -p"$P" -D "$N" -e \
  "SELECT shortname, name, archetype FROM mdl_role WHERE shortname IN ('manager','editingteacher');"
echo ""
echo "=== PURGING CACHES ==="
sudo -u apache php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || echo "cache purge attempted"
echo "=== DONE ==="
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bash))
$tmp = Join-Path $env:TEMP 'fix-lp-syscaps.json'
@{ commands = @(
  "echo '$b64' | base64 -d > /tmp/fix-lp-syscaps.sh",
  'chmod +x /tmp/fix-lp-syscaps.sh',
  '/tmp/fix-lp-syscaps.sh'
) } | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8

Write-Host 'Sending SSM command...'
$cmdId = ((aws @awsArgs ssm send-command --region $Region `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$tmp" `
  --query 'Command.CommandId' --output text | Out-String).Trim())
Write-Host "CommandId: $cmdId"

$deadline = (Get-Date).AddSeconds(180)
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
Write-Host "=== OUTPUT ==="
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "=== STDERR ==="; Write-Host $r.StandardErrorContent }

