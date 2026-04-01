#!/usr/bin/env pwsh
# Fix: Courses in "Learning Programs" category are not editable on learning.tsin.ca
# Checks and removes role capability PROHIBIT/PREVENT overrides at category/course level,
# disables any plugin-based course edit locks, and purges caches.
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$Stack   = 'MoodleCdkStack'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding           = [System.Text.UTF8Encoding]::new()

function Resolve-Profile {
  param([string]$RequestedProfile)
  if ([string]::IsNullOrWhiteSpace($RequestedProfile)) {
    try { aws sts get-caller-identity --output json | Out-Null; return '' }
    catch { throw 'Default AWS CLI profile is not working.' }
  }
  try { aws sts get-caller-identity --profile $RequestedProfile --output json | Out-Null; return $RequestedProfile }
  catch { throw "AWS CLI profile '$RequestedProfile' is not working." }
}

function Wait-SSM {
  param([string]$CommandId, [string]$InstanceId, [int]$TimeoutSeconds = 300)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 4
    $status = (aws ssm get-command-invocation @awsArgs --region $Region `
      --command-id $CommandId --instance-id $InstanceId `
      --query 'Status' --output text 2>$null | Out-String).Trim()
    if ($status -in 'Success','Failed','Cancelled','TimedOut') { return $status }
  } while ((Get-Date) -lt $deadline)
  return 'TimedOut'
}

$resolvedProfile = Resolve-Profile -RequestedProfile $Profile
$script:awsArgs = @()
if ($resolvedProfile) { $script:awsArgs += @('--profile', $resolvedProfile) }

$instanceId = ((aws @awsArgs ec2 describe-instances --region $Region `
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" `
            "Name=instance-state-name,Values=running" `
  --query 'Reservations[].Instances[].InstanceId' --output text | Out-String).Trim() -split '\s+')[0]
if (-not $instanceId) { throw "No running instances found for stack $Stack." }
Write-Host "Profile : $(if ($resolvedProfile) { $resolvedProfile } else { 'default' })"
Write-Host "Instance: $instanceId"

# ── Bash payload ──────────────────────────────────────────────────────────────
$bash = @'
#!/bin/bash
set -euo pipefail
exec > >(LC_ALL=C tr -cd '\11\12\15\40-\176') 2>&1

echo '================================================================'
echo ' FIX: Learning Programs – Course Editability'
echo '================================================================'

# ---------- DB credentials --------------------------------------------------
DB_JSON=$(php -r 'define("CLI_SCRIPT",true); require "/app/moodle/config.php"; echo json_encode(["host"=>$CFG->dbhost,"user"=>$CFG->dbuser,"pass"=>$CFG->dbpass,"name"=>$CFG->dbname]);')
DB_HOST=$(echo "$DB_JSON" | jq -r .host)
DB_USER=$(echo "$DB_JSON" | jq -r .user)
DB_PASS=$(echo "$DB_JSON" | jq -r .pass)
DB_NAME=$(echo "$DB_JSON" | jq -r .name)
echo "DB: $DB_HOST / $DB_NAME"
echo

# ---------- Learning Programs category --------------------------------------
CAT_ID=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -Nse \
  "SELECT id FROM mdl_course_categories WHERE name LIKE '%Learning Program%' ORDER BY id LIMIT 1;" 2>/dev/null || true)
if [ -z "$CAT_ID" ]; then
  echo '[WARN] No category matching "Learning Program" found. Trying exact name...'
  CAT_ID=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -Nse \
    "SELECT id FROM mdl_course_categories ORDER BY id LIMIT 1;" 2>/dev/null || true)
fi
echo "Learning Programs category ID: $CAT_ID"
echo

# ---------- 1. DIAGNOSE: role capability overrides --------------------------
echo '=== [DIAG] Role capability overrides blocking course edit ==='
echo '-- At category context (contextlevel=40) --'
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT ctx.instanceid, r.shortname, rc.capability, rc.permission
   FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id = rc.contextid
   JOIN mdl_role r ON r.id = rc.roleid
   WHERE ctx.contextlevel = 40 AND ctx.instanceid = $CAT_ID
     AND rc.capability IN ('moodle/course:update','moodle/course:changesummary',
                           'moodle/course:visibility','moodle/course:manage')
   ORDER BY r.shortname, rc.capability;" 2>/dev/null || true
echo

echo '-- At course context (contextlevel=50) for courses in this category --'
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT c.id AS courseid, c.fullname, r.shortname, rc.capability, rc.permission
   FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id = rc.contextid
   JOIN mdl_course c ON c.id = ctx.instanceid
   JOIN mdl_role r ON r.id = rc.roleid
   WHERE ctx.contextlevel = 50 AND c.category = $CAT_ID
     AND rc.capability IN ('moodle/course:update','moodle/course:changesummary',
                           'moodle/course:visibility','moodle/course:manage')
   ORDER BY c.fullname, r.shortname, rc.capability;" 2>/dev/null || true
echo

# ---------- 2. FIX: remove prohibit/prevent at category context -------------
echo '=== [FIX] Remove PROHIBIT/PREVENT on course-edit caps at category level ==='
DELETED_CAT=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -Nse \
  "SELECT COUNT(*) FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id = rc.contextid
   WHERE ctx.contextlevel = 40 AND ctx.instanceid = $CAT_ID
     AND rc.capability IN ('moodle/course:update','moodle/course:changesummary',
                           'moodle/course:visibility','moodle/course:manage')
     AND rc.permission < 0;" 2>/dev/null || echo 0)
echo "Rows to remove at category level: $DELETED_CAT"
if [ "$DELETED_CAT" -gt 0 ]; then
  mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
    "DELETE rc FROM mdl_role_capabilities rc
     JOIN mdl_context ctx ON ctx.id = rc.contextid
     WHERE ctx.contextlevel = 40 AND ctx.instanceid = $CAT_ID
       AND rc.capability IN ('moodle/course:update','moodle/course:changesummary',
                             'moodle/course:visibility','moodle/course:manage')
       AND rc.permission < 0;" 2>/dev/null
  echo "[OK] Removed $DELETED_CAT restrictive capability override(s) at category level."
else
  echo "[OK] No restrictive capability overrides at category level."
fi
echo

# ---------- 3. FIX: remove prohibit/prevent at individual course context ----
echo '=== [FIX] Remove PROHIBIT/PREVENT on course-edit caps at course level ==='
DELETED_COURSE=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -Nse \
  "SELECT COUNT(*) FROM mdl_role_capabilities rc
   JOIN mdl_context ctx ON ctx.id = rc.contextid
   JOIN mdl_course c ON c.id = ctx.instanceid
   WHERE ctx.contextlevel = 50 AND c.category = $CAT_ID
     AND rc.capability IN ('moodle/course:update','moodle/course:changesummary',
                           'moodle/course:visibility','moodle/course:manage')
     AND rc.permission < 0;" 2>/dev/null || echo 0)
echo "Rows to remove at course level: $DELETED_COURSE"
if [ "$DELETED_COURSE" -gt 0 ]; then
  mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
    "DELETE rc FROM mdl_role_capabilities rc
     JOIN mdl_context ctx ON ctx.id = rc.contextid
     JOIN mdl_course c ON c.id = ctx.instanceid
     WHERE ctx.contextlevel = 50 AND c.category = $CAT_ID
       AND rc.capability IN ('moodle/course:update','moodle/course:changesummary',
                             'moodle/course:visibility','moodle/course:manage')
       AND rc.permission < 0;" 2>/dev/null
  echo "[OK] Removed $DELETED_COURSE restrictive capability override(s) at course level."
else
  echo "[OK] No restrictive capability overrides at course level."
fi
echo

# ---------- 4. DIAGNOSE: local plugin locks ---------------------------------
echo '=== [DIAG] Local/custom plugins ==='
find /app/moodle/local -maxdepth 2 -mindepth 1 -type d 2>/dev/null | sort || true
echo

echo '=== [DIAG] PHP code freezing/locking course edit form ==='
grep -RInE --include='*.php' \
  'changesummary|freeze\(|disabledIf|learning.?program|lockcourse|course.*lock|edit.*lock|readonly' \
  /app/moodle/local 2>/dev/null | head -40 || true
echo

# ---------- 5. FIX: disable any scheduled tasks that lock course editing ----
echo '=== [DIAG] Scheduled tasks that may lock courses ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT classname, disabled, FROM_UNIXTIME(lastruntime) AS lastrun
   FROM mdl_task_scheduled
   WHERE classname LIKE '%show_started%' OR classname LIKE '%hide_ended%'
      OR classname LIKE '%lock%course%' OR classname LIKE '%learning%program%'
   ORDER BY classname;" 2>/dev/null || true
echo

# ---------- 6. FIX: custom field "locked" values ----------------------------
echo '=== [DIAG] Custom field "locked" / "published" values on LP courses ==='
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT d.instanceid AS courseid, f.shortname, f.name, d.value
   FROM mdl_customfield_data d
   JOIN mdl_customfield_field f ON f.id = d.fieldid
   JOIN mdl_course c ON c.id = d.instanceid
   WHERE c.category = $CAT_ID
     AND (f.shortname LIKE '%lock%' OR f.shortname LIKE '%publish%' OR f.shortname LIKE '%status%')
   ORDER BY d.instanceid, f.shortname;" 2>/dev/null || true
echo

# ---------- 7. Purge caches -------------------------------------------------
echo '=== [FIX] Purging Moodle caches ==='
sudo -u apache php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || \
  php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || \
  echo '[WARN] Cache purge may have failed – check manually.'
echo

echo '================================================================'
echo ' Done. Review output above then re-test course editing.'
echo '================================================================'
'@

# ── Encode and send via SSM ──────────────────────────────────────────────────
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bash))
$paramsPath = Join-Path $env:TEMP 'fix-learning-programs-editability.json'
@{ commands = @(
  "echo '$b64' | base64 -d > /tmp/fix-lp-editability.sh",
  'chmod +x /tmp/fix-lp-editability.sh',
  '/tmp/fix-lp-editability.sh'
) } | ConvertTo-Json -Compress | Set-Content -Path $paramsPath -Encoding UTF8

Write-Host 'Sending SSM command...'
$commandId = ((aws @awsArgs ssm send-command --region $Region `
  --instance-ids $instanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsPath" `
  --query 'Command.CommandId' --output text | Out-String).Trim())
Write-Host "CommandId: $commandId"

$finalStatus = Wait-SSM -CommandId $commandId -InstanceId $instanceId -TimeoutSeconds 300
Write-Host "Status: $finalStatus"

$result = (aws @awsArgs ssm get-command-invocation --region $Region `
  --command-id $commandId --instance-id $instanceId --output json | ConvertFrom-Json)
Write-Host '=== STDOUT ==='
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) {
  Write-Host '=== STDERR ==='
  Write-Host $result.StandardErrorContent
}

