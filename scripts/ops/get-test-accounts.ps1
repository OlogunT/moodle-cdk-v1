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
H=$(grep -m1 "CFG->dbhost"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

echo "=== TEST/ADMIN ACCOUNTS ==="
$DB -e "SELECT id, username, email, firstname, lastname, auth, FROM_UNIXTIME(lastlogin) AS lastlogin FROM mdl_user WHERE (username LIKE '%test%' OR username LIKE '%admin%') AND deleted=0 ORDER BY lastlogin DESC;" 2>&1
'@

$paramsFile = Join-Path $env:TEMP 'get-test-accounts-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 30 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Start-Sleep 15
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

