#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '60')

$bash = @'
echo "=== CHECK localcachedir CONFIG ==="
grep -i "localcache" /app/moodle/config.php || echo "No localcachedir in config.php"

echo "=== CHECK DEFAULT localcachedir ==="
ls -la /app/moodledata/localcache/ 2>&1 || echo "localcache dir does not exist"

echo "=== CHECK dataroot ==="
grep "dataroot" /app/moodle/config.php | head -3
ls -la /app/moodledata/ | head -10

echo "=== CREATE localcache DIRECTORY ==="
DATAROOT=$(grep -m1 "CFG->dataroot" /app/moodle/config.php | sed "s/.*'\([^']*\)'.*/\1/")
echo "Dataroot: $DATAROOT"
mkdir -p "$DATAROOT/localcache" 2>&1
chown apache:apache "$DATAROOT/localcache" 2>&1
chmod 775 "$DATAROOT/localcache" 2>&1
ls -la "$DATAROOT/localcache" 2>&1 || echo "Still no localcache"

echo "=== BUILD COMPONENT CACHE via PHP CLI ==="
timeout 60 php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$cache = \\core\\component::get_component_list();
echo 'Components loaded: ' . count(\$cache) . PHP_EOL;
echo 'Cache dir: ' . (\$CFG->localcachedir ?? 'default') . PHP_EOL;
" 2>&1
echo "PHP exit: $?"

echo "=== CHECK localcache CONTENTS ==="
find "$DATAROOT/localcache" -type f 2>/dev/null | head -20 || echo "No files"

echo "=== RESTART PHP-FPM ==="
systemctl restart php-fpm 2>&1
sleep 3
echo "Restarted"

echo "=== TEST LOGIN SPEED ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 http://localhost/login/index.php 2>&1
echo "=== TEST 2 ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 http://localhost/login/index.php 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'fix-localcache-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 90
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

