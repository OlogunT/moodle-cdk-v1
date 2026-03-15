#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== DISK VERSION vs DB VERSION ==="
echo "Disk core version:"
grep '^\$version' /app/moodle/version.php
echo "DB core version:"
$DB -sN -e "SELECT value FROM mdl_config WHERE name='version';" 2>&1

echo "=== ALL PLUGIN DISK VERSIONS (from version.php files) ==="
find /app/moodle -name "version.php" -path "*/format/menutopic/*" -exec grep 'plugin->version' {} \;
find /app/moodle -name "version.php" -path "*/local/*" -exec grep 'plugin->version' {} \; 2>/dev/null | head -20
find /app/moodle -name "version.php" -path "*/mod/*" -exec grep 'plugin->version' {} \; 2>/dev/null | head -20

echo "=== DB PLUGIN VERSIONS ==="
$DB -e "SELECT plugin, value FROM mdl_config_plugins WHERE name='version' ORDER BY plugin;" 2>&1

echo "=== CHECK FOR UNINSTALLED/MISSING PLUGINS ==="
$DB -e "SELECT plugin, value FROM mdl_config_plugins WHERE name='version' AND plugin NOT LIKE 'core%' ORDER BY plugin;" 2>&1 | head -50

echo "=== UPGRADE.PHP VERBOSE TEST (10s only) ==="
timeout 10 php /app/moodle/admin/cli/upgrade.php --non-interactive --verbose 2>&1 || echo "Timed out (expected)"

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'check-ver-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Start-Sleep 30
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

