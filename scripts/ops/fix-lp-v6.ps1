#!/usr/bin/env pwsh
# Diagnose Learning Programs editability - check theme, PHP errors, course settings
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
$DB -e "SELECT name, value FROM mdl_config WHERE name IN ('theme','themedir') ORDER BY name;" 2>&1
$DB -e "SELECT plugin, name, value FROM mdl_config_plugins WHERE plugin='core_admin' AND name LIKE '%theme%';" 2>&1

echo "=== COURSE FORMAT PLUGINS INSTALLED ==="
ls /app/moodle/course/format/ 2>&1

echo "=== MENUTOPIC FORMAT EXISTS ==="
ls /app/moodle/course/format/menutopic/ 2>&1 | head -10

echo "=== PHP ERROR LOG (last 50 lines) ==="
PHPLOG=$(php -r "echo ini_get('error_log');" 2>/dev/null)
if [ -f "$PHPLOG" ]; then
  tail -50 "$PHPLOG" 2>&1
else
  echo "PHP log not found at: $PHPLOG"
  # Check common locations
  for f in /var/log/php*.log /var/log/apache2/error.log /var/log/nginx/error.log /tmp/php_errors.log; do
    if [ -f "$f" ]; then echo "Found log: $f"; tail -30 "$f"; fi
  done
fi

echo "=== MOODLE ERROR LOG (recent, last 20) ==="
$DB -e "SELECT FROM_UNIXTIME(timecreated) AS ts, component, action, info
FROM mdl_logstore_standard_log
WHERE action='failed' OR info LIKE '%error%' OR info LIKE '%exception%'
ORDER BY timecreated DESC LIMIT 20;" 2>&1

echo "=== COURSE SETTINGS FOR CAT 33 (check locks/restrictions) ==="
$DB -e "SELECT id, fullname, format, enablecompletion, groupmode, groupmodeforce,
  defaultgroupingid, lang, theme, visible, visibleold
FROM mdl_course WHERE category=33 ORDER BY id;" 2>&1

echo "=== CONFIG_PLUGINS FOR COURSE EDITING ==="
$DB -e "SELECT plugin, name, value FROM mdl_config_plugins
WHERE (plugin='format_weeks' OR plugin='format_topics' OR plugin='format_menutopic')
AND name IN ('enabled','disableajax');" 2>&1

echo "=== CHECK FOR MOODLE MAINTENANCE MODE ==="
$DB -e "SELECT name, value FROM mdl_config WHERE name IN ('maintenance_enabled','maintenance_message','siteprotection');" 2>&1

echo "=== CHECK BACKUP CONTROLLERS FOR LOCKED COURSES ==="
$DB -e "SELECT bc.type, bc.itemid, bc.status, bc.operation,
  CASE WHEN bc.type='course' THEN (SELECT fullname FROM mdl_course WHERE id=bc.itemid LIMIT 1) END AS course_name
FROM mdl_backup_controllers bc
WHERE bc.type='course' AND bc.itemid IN (SELECT id FROM mdl_course WHERE category=33)
AND bc.status NOT IN (0, 1000);" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v6.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v6-params.json'
@{
  commands = @(
    "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v6.sh",
    "chmod +x /tmp/fix-lp-v6.sh",
    "timeout 90 /tmp/fix-lp-v6.sh"
  )
} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" `
  --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

