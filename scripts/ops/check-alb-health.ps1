#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

# 1. Check Apache status on the instance
$bash = @'
echo "=== APACHE STATUS ==="
systemctl is-active httpd 2>&1 || systemctl is-active apache2 2>&1

echo "=== APACHE LISTENING PORTS ==="
ss -tlnp | grep -E "httpd|apache|:80|:443" 2>&1

echo "=== APACHE ERROR LOG (last 30 lines) ==="
tail -30 /var/log/httpd/error_log 2>/dev/null || tail -30 /var/log/apache2/error.log 2>/dev/null || echo "No Apache error log found"

echo "=== MOODLE MAINTENANCE MODE (DB) ==="
CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname"  "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
mariadb -h $H -u $U -p$P -D $N -e "SELECT name, value FROM mdl_config WHERE name IN ('maintenance_enabled','siteidentifier','wwwroot');" 2>&1
'@

$paramsFile = Join-Path $env:TEMP 'check-alb-params.json'
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
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

# 2. Check ALB target group health
Write-Host "`n=== ALB TARGET GROUP HEALTH ==="
$tgs = aws @awsArgs elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output json | ConvertFrom-Json
foreach ($tg in $tgs) {
  Write-Host "Target Group: $tg"
  aws @awsArgs elbv2 describe-target-health --target-group-arn $tg --output table 2>&1
}

