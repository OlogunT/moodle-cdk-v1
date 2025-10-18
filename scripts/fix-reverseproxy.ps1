param(
  [string]$Region = "ca-central-1",
  [string]$StackName = "MoodleCdkStack",
  [string]$CustomDomain,            # e.g. https://elearning.tsin.ca (optional)
  [switch]$UseAlbOutput,            # If set, fetches MoodleUrl from CloudFormation outputs
  [switch]$VerifyAfter              # If set, runs a quick external verify script after changes
)

# Safe, repeatable fixer for Moodle reverse-proxy redirect loops
# - Ensures $CFG->reverseproxy = true and $CFG->sslproxy = true in /app/moodle/config.php
# - Optionally sets $CFG->wwwroot to a provided CustomDomain or the ALB output MoodleUrl
# - Purges caches and restarts Apache/PHP-FPM
# - Operates on all healthy instances in the Moodle ASG via AWS SSM

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-TargetUrl {
  param([string]$Region,[string]$StackName,[string]$CustomDomain,[switch]$UseAlbOutput)
  if ($CustomDomain) { return $CustomDomain }
  if ($UseAlbOutput) {
    $albUrl = aws cloudformation describe-stacks --region $Region --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='MoodleUrl'].OutputValue" --output text 2>$null
    if ($albUrl -and $albUrl -ne 'None') { return $albUrl }
    throw "Could not resolve MoodleUrl from stack outputs; specify -CustomDomain"
  }
  return $null
}

function Get-MoodleAsgName {
  param([string]$Region)
  $asgName = aws autoscaling describe-auto-scaling-groups --region $Region --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName | [0]" --output text 2>$null
  if (-not $asgName -or $asgName -eq 'None') { throw "Could not find Moodle Auto Scaling Group" }
  return $asgName
}

function Get-HealthyInstancesFromAsg {
  param([string]$Region,[string]$AsgName)
  $instancesText = aws autoscaling describe-auto-scaling-groups --region $Region --auto-scaling-group-names $AsgName --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy' && LifecycleState=='InService'].InstanceId" --output text 2>$null
  if (-not $instancesText) { throw "No healthy instances found in ASG $AsgName" }
  return ($instancesText -split "`t" | Where-Object { $_ })
}

function Build-RemoteCommandsJson {
  param([string]$Region,[string]$TargetUrl)

  $cmds = @()
  if ($TargetUrl) { $cmds += "export TARGET_URL='$TargetUrl'" }
  $cmds += @(
    "export REGION='$Region'",
    'set -euo pipefail',
    'echo ''=== FIXING MOODLE REVERSE PROXY SETTINGS ===''',
    'CFG=/app/moodle/config.php',
    'if [ ! -f "$CFG" ]; then echo ''Config not found at /app/moodle/config.php''; exit 1; fi',
    'echo ''--- BEFORE (grep) ---''',
    'grep -nE ''(wwwroot|reverseproxy|sslproxy)'' "$CFG" || true',
    'echo ''Creating backup of config.php''',
    'cp "$CFG" "$CFG.backup.$(date +%Y%m%d_%H%M%S)"',

    'cat > /tmp/moodle-fix-reverseproxy.sh << ''EOS''',
    '#!/bin/bash',
    'set -euo pipefail',
    'CFG=/app/moodle/config.php',
    'insert_before_require() {',
    '  local line="$1"',
    '  # Insert the line before the first require_once line if it does not already exist',
    '  if ! grep -q "^$line$" "$CFG"; then',
    '    sed -i "/require_once/i$line" "$CFG"',
    '  fi',
    '}',
    'ensure_setting_true() {',
    '  local key="$1" # e.g., reverseproxy',
    '  if grep -q "^\$CFG->$key" "$CFG"; then',
    '    sed -i "s|^\$CFG->$key.*|\$CFG->$key = true;|" "$CFG"',
    '  else',
    '    insert_before_require "\$CFG->$key = true;"',
    '  fi',
    '}',
    'set_wwwroot() {',
    '  local url="$1"',
    '  if grep -q "^\$CFG->wwwroot" "$CFG"; then',
    '    sed -i "s|^\$CFG->wwwroot.*|\$CFG->wwwroot = ''$url'';|" "$CFG"',
    '  else',
    '    insert_before_require "\$CFG->wwwroot = ''$url'';"',
    '  fi',
    '}',
    'update_db_wwwroot() {',
    '  local url="$1"',
    '  # Attempt DB update for mdl_config.wwwroot (best-effort)',
    '  if command -v aws >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v mariadb >/dev/null 2>&1; then',
    '    DB_SECRET=$(aws secretsmanager list-secrets --region "$REGION" --query "SecretList[?contains(Name, ''MoodleDbSecret'')].ARN | [0]" --output text 2>/dev/null || true)',
    '    if [ -n "$DB_SECRET" ] && [ "$DB_SECRET" != "None" ]; then',
    '      DB_JSON=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$DB_SECRET" --query SecretString --output text 2>/dev/null || true)',
    '      DB_HOST=$(echo "$DB_JSON" | jq -r .host 2>/dev/null || true)',
    '      DB_USER=$(echo "$DB_JSON" | jq -r .username 2>/dev/null || true)',
    '      DB_PASS=$(echo "$DB_JSON" | jq -r .password 2>/dev/null || true)',
    '      DB_NAME=$(echo "$DB_JSON" | jq -r .dbname 2>/dev/null || echo moodle)',
    '      if [ -n "$DB_HOST" ] && [ "$DB_HOST" != "null" ]; then',
    '        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "UPDATE mdl_config SET value=''''$url'''' WHERE name=''''wwwroot'''';" >/dev/null 2>&1 || true',
    '      fi',
    '    fi',
    '  fi',
    '}',
    'main() {',
    '  # Ensure reverse proxy flags',
    '  ensure_setting_true reverseproxy',
    '  ensure_setting_true sslproxy',
    '  # Optionally set wwwroot from TARGET_URL',
    '  if [ -n "${TARGET_URL:-}" ]; then',
    '    set_wwwroot "$TARGET_URL"',
    '    update_db_wwwroot "$TARGET_URL" || true',
    '  fi',
    '  # Syntax check',
    '  php -l "$CFG"',
    '  # Purge caches (best-effort)',
    '  sudo -u apache php /app/moodle/admin/cli/purge_caches.php >/dev/null 2>&1 || true',
    '  # Restart services',
    '  systemctl restart php-fpm httpd || systemctl restart httpd || true',
    '}',
    'main',
    'EOS',
    'bash /tmp/moodle-fix-reverseproxy.sh',

    'echo ''--- AFTER (grep) ---''',
    'grep -nE ''(wwwroot|reverseproxy|sslproxy)'' "$CFG" || true',
    'echo ''=== FIX COMPLETE ==='''
  )

  return (@{ commands = $cmds } | ConvertTo-Json -Compress)
}

function Invoke-SSMFix {
  param([string]$Region,[string[]]$InstanceIds,[string]$CommandsJson)
  $tmpFile = New-TemporaryFile
  try {
    [System.IO.File]::WriteAllText($tmpFile.FullName, $CommandsJson, [System.Text.UTF8Encoding]::new($false))
    $cmdId = aws ssm send-command --region $Region --instance-ids $InstanceIds --document-name AWS-RunShellScript --parameters "file://$($tmpFile.FullName)" --query "Command.CommandId" --output text
    if (-not $cmdId -or $cmdId -eq 'None') { throw "Failed to send SSM command" }
    Write-Host ("Command sent: {0}" -f $cmdId)

    # Wait and fetch outputs per instance
    Start-Sleep -Seconds 10
    foreach ($iid in $InstanceIds) {
      Write-Host ("\n--- Output for {0} ---" -f $iid) -ForegroundColor Cyan
      $status = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $iid --query "Status" --output text
      Write-Host ("Status: {0}" -f $status)
      $stdout = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $iid --query "StandardOutputContent" --output text
      $stderr = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $iid --query "StandardErrorContent" --output text
      "==== STDOUT ===="
      $stdout
      if ($stderr) {
        "==== STDERR ===="
        $stderr
      }
    }
  } finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
  }
}

# Resolve target URL (optional)
$targetUrl = Get-TargetUrl -Region $Region -StackName $StackName -CustomDomain $CustomDomain -UseAlbOutput:$UseAlbOutput
if ($targetUrl) { Write-Host ("Using target URL: {0}" -f $targetUrl) -ForegroundColor Green }

# Discover instances
$asgName = Get-MoodleAsgName -Region $Region
$instanceIds = Get-HealthyInstancesFromAsg -Region $Region -AsgName $asgName
Write-Host ("Found {0} healthy instance(s): {1}" -f $instanceIds.Count, ($instanceIds -join ', ')) -ForegroundColor Green

# Build and send SSM command
$commandsJson = Build-RemoteCommandsJson -Region $Region -TargetUrl $targetUrl
Invoke-SSMFix -Region $Region -InstanceIds $instanceIds -CommandsJson $commandsJson

if ($VerifyAfter) {
  try {
    Write-Host "\n=== Running verify-external-http.ps1 ===" -ForegroundColor Yellow
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'verify-external-http.ps1') -Region $Region -Stack $StackName | Write-Host
  } catch {
    Write-Host "Verification step failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

