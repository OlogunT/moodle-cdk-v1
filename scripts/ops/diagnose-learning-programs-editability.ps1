Param(
  [string]$Profile = 'tsin-account',
  [string]$Region = 'ca-central-1',
  [string]$Stack = 'MoodleCdkStack'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Resolve-Profile {
  param([string]$RequestedProfile)

  if ([string]::IsNullOrWhiteSpace($RequestedProfile)) {
    try {
      aws sts get-caller-identity --output json | Out-Null
      return ''
    } catch {
      throw 'Default AWS CLI profile is not working.'
    }
  }

  try {
    aws sts get-caller-identity --profile $RequestedProfile --output json | Out-Null
    return $RequestedProfile
  } catch {
    throw "AWS CLI profile '$RequestedProfile' is not working."
  }
}

$profile = Resolve-Profile -RequestedProfile $Profile
$awsArgs = @()
if ($profile) { $awsArgs += @('--profile', $profile) }

$instanceIdsText = ((& aws @awsArgs ec2 describe-instances --region $Region --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text | Out-String).Trim())
if (-not $instanceIdsText) { throw "No running instances found for $Stack." }
$instanceId = ($instanceIdsText -split '\s+')[0]

Write-Host "Profile: $(if ($profile) { $profile } else { 'default' })"
Write-Host "Instance: $instanceId"

$bash = @'
#!/bin/bash
set -euo pipefail
exec > >(LC_ALL=C tr -cd '\11\12\15\40-\176') 2>&1

echo '=== DB CONFIG ==='
DB_JSON=$(php -r 'define("CLI_SCRIPT", true); require "/app/moodle/config.php"; echo json_encode(["host"=>$CFG->dbhost,"user"=>$CFG->dbuser,"pass"=>$CFG->dbpass,"name"=>$CFG->dbname]);')
DB_HOST=$(echo "$DB_JSON" | jq -r .host)
DB_USER=$(echo "$DB_JSON" | jq -r .user)
DB_PASS=$(echo "$DB_JSON" | jq -r .pass)
DB_NAME=$(echo "$DB_JSON" | jq -r .name)
echo "DB_HOST=$DB_HOST DB_NAME=$DB_NAME"
echo

echo '=== CRON STATUS ==='
echo '-- enabled --'
systemctl is-enabled crond || true
echo '-- active --'
systemctl is-active crond || true
echo '-- service state --'
systemctl show -p ActiveState -p SubState crond || true
echo '-- apache crontab --'
crontab -u apache -l || true
echo

echo '=== RECENT MOODLE TASKS (BACKUP/COPY/COURSE VISIBILITY) ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT classname, disabled, FROM_UNIXTIME(lastruntime) AS lastrun FROM mdl_task_scheduled WHERE classname LIKE '%backup%' OR classname LIKE '%copy%' OR classname LIKE '%show_started_courses%' OR classname LIKE '%hide_ended_courses%' ORDER BY lastruntime DESC;"
echo

echo '=== BACKUP/COPY QUEUE HEALTH ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT status, COUNT(*) AS cnt FROM mdl_backup_controllers GROUP BY status ORDER BY status;"
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT classname, faildelay, attemptsavailable, FROM_UNIXTIME(nextruntime) AS nextrun FROM mdl_task_adhoc WHERE classname LIKE '%backup%' OR classname LIKE '%copy%' ORDER BY nextruntime DESC LIMIT 20;"
echo

echo '=== LEARNING PROGRAMS CATEGORY ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT id, name, parent, path, depth, visible FROM mdl_course_categories WHERE name LIKE '%Learning Program%';"
CAT_ID=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -Nse "SELECT id FROM mdl_course_categories WHERE name LIKE '%Learning Program%' ORDER BY id LIMIT 1;")
echo "CAT_ID=$CAT_ID"
echo

echo '=== COURSES UNDER LEARNING PROGRAMS ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT id, fullname, shortname, visible, LENGTH(COALESCE(summary,'')) AS summary_len, summaryformat FROM mdl_course WHERE category = $CAT_ID ORDER BY fullname;"
echo

echo '=== AFFECTED COURSES ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT id, fullname, shortname, category, visible, LENGTH(COALESCE(summary,'')) AS summary_len, summaryformat FROM mdl_course WHERE fullname LIKE '%Foundat%Module%2026%' OR fullname LIKE '%Welcome/Orientation Module%';"
COURSE_IDS=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -Nse "SELECT id FROM mdl_course WHERE fullname LIKE '%Foundat%Module%2026%' OR fullname LIKE '%Welcome/Orientation Module%';" | tr '\n' ',' | sed 's/,$//')
echo "COURSE_IDS=$COURSE_IDS"
echo

echo '=== GLOBAL ROLE CAPABILITIES FOR COURSE EDITING ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT r.shortname, rc.capability, rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id = rc.contextid JOIN mdl_role r ON r.id = rc.roleid WHERE ctx.contextlevel = 10 AND r.shortname IN ('manager','editingteacher','teacher','student') AND rc.capability IN ('moodle/course:update','moodle/course:changesummary','moodle/course:visibility') ORDER BY r.shortname, rc.capability;"
echo

echo '=== CUSTOM FIELDS FOR AFFECTED COURSES ==='
if [ -n "$COURSE_IDS" ]; then
  mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT d.instanceid AS courseid, f.shortname, f.name, d.value FROM mdl_customfield_data d JOIN mdl_customfield_field f ON f.id = d.fieldid WHERE d.instanceid IN ($COURSE_IDS) ORDER BY d.instanceid, f.name;"
else
  echo 'No affected course ids found'
fi
echo

echo '=== ROLE CAPABILITY OVERRIDES (CATEGORY + AFFECTED COURSES) ==='
if [ -n "$COURSE_IDS" ]; then
  mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT ctx.contextlevel, ctx.instanceid, r.shortname AS role_shortname, rc.capability, rc.permission FROM mdl_role_capabilities rc JOIN mdl_context ctx ON ctx.id = rc.contextid JOIN mdl_role r ON r.id = rc.roleid WHERE rc.capability IN ('moodle/course:update','moodle/course:changesummary','moodle/course:visibility') AND ((ctx.contextlevel = 40 AND ctx.instanceid = $CAT_ID) OR (ctx.contextlevel = 50 AND ctx.instanceid IN ($COURSE_IDS))) ORDER BY ctx.contextlevel, ctx.instanceid, r.shortname, rc.capability;"
else
  echo 'No affected course ids found'
fi
echo

echo '=== ROLE ASSIGNMENTS SUMMARY IN LEARNING PROGRAMS CATEGORY ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT c.fullname, r.shortname, COUNT(*) AS assignments FROM mdl_role_assignments ra JOIN mdl_context ctx ON ctx.id = ra.contextid AND ctx.contextlevel = 50 JOIN mdl_course c ON c.id = ctx.instanceid JOIN mdl_role r ON r.id = ra.roleid WHERE c.category = $CAT_ID GROUP BY c.fullname, r.shortname ORDER BY c.fullname, r.shortname;"
echo

echo '=== LOCAL/CUSTOM PLUGINS ==='
find /app/moodle/local -maxdepth 2 -mindepth 1 -type d 2>/dev/null | sort || true
echo

echo '=== SEARCH FOR SUMMARY/COURSE EDIT CUSTOMIZATIONS ==='
grep -RInE --include='*.php' 'changesummary|summary_editor|disabledIf|freeze\(|publish|learning program' /app/moodle/local /app/moodle/course/edit_form.php /app/moodle/course/lib.php /app/moodle/admin/tool 2>/dev/null | head -60 || true
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bash))
$paramsPath = Join-Path $env:TEMP 'diagnose-learning-programs-editability.json'
@{ commands = @(
  "echo '$b64' | base64 -d > /tmp/diagnose-learning-programs-editability.sh",
  'chmod +x /tmp/diagnose-learning-programs-editability.sh',
  '/tmp/diagnose-learning-programs-editability.sh'
) } | ConvertTo-Json -Compress | Set-Content -Path $paramsPath -Encoding UTF8

$commandId = ((& aws @awsArgs ssm send-command --region $Region --instance-ids $instanceId --document-name AWS-RunShellScript --parameters ("file://$paramsPath") --query 'Command.CommandId' --output text | Out-String).Trim())
Write-Host "CommandId: $commandId"

for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 3
  $status = ((& aws @awsArgs ssm get-command-invocation --region $Region --command-id $commandId --instance-id $instanceId --query 'Status' --output text 2>$null | Out-String).Trim())
  if ($status -in @('Success', 'Failed', 'Cancelled', 'TimedOut')) {
    Write-Host "Status: $status"
    & aws @awsArgs ssm get-command-invocation --region $Region --command-id $commandId --instance-id $instanceId --output json
    exit 0
  }
}

Write-Host 'Status: still running'
& aws @awsArgs ssm get-command-invocation --region $Region --command-id $commandId --instance-id $instanceId --output json

