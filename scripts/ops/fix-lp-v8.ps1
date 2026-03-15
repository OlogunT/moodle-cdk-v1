#!/usr/bin/env pwsh
# Diagnose LP editability - check menutopic plugin health and PHP errors
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
#!/bin/bash

echo "=== MENUTOPIC PLUGIN FILES ==="
ls -la /app/moodle/course/format/menutopic/ 2>&1 | head -30

echo "=== MENUTOPIC VERSION.PHP ==="
cat /app/moodle/course/format/menutopic/version.php 2>&1

echo "=== PHP SYNTAX CHECK - MENUTOPIC LIB.PHP ==="
php -l /app/moodle/course/format/menutopic/lib.php 2>&1

echo "=== PHP SYNTAX CHECK - MENUTOPIC FORMAT.PHP ==="
php -l /app/moodle/course/format/menutopic/format.php 2>&1

echo "=== PHP SYNTAX CHECK - ALL MENUTOPIC PHP FILES ==="
find /app/moodle/course/format/menutopic -name "*.php" | xargs -I{} php -l {} 2>&1 | grep -v "No syntax errors" | head -20

echo "=== MOODLE ERROR LOG (last 10 lines only) ==="
PHPLOG=$(php -r "echo ini_get('error_log');" 2>/dev/null)
if [ -f "$PHPLOG" ]; then
  echo "Log: $PHPLOG"
  wc -l "$PHPLOG"
  tail -10 "$PHPLOG" 2>&1
else
  echo "PHP log not found at: $PHPLOG"
  for f in /var/log/php*.log /tmp/php_errors.log; do
    if [ -f "$f" ]; then echo "Found: $f ($(wc -l < $f) lines)"; tail -5 "$f"; fi
  done
fi

echo "=== MOODLE LOCAL PLUGINS ==="
ls /app/moodle/local/ 2>&1

echo "=== MOODLE ADMIN PLUGINS DB (recently installed/upgraded) ==="
CONFIG=/app/moodle/config.php
extract_cfg() { grep -m1 "CFG->${1}" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/"; }
H=$(extract_cfg dbhost); U=$(extract_cfg dbuser); P=$(extract_cfg dbpass); N=$(extract_cfg dbname)
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=10"

$DB -e "SELECT plugin, version, FROM_UNIXTIME(timemodified) AS modified
FROM mdl_config_plugins
WHERE plugin LIKE '%menutopic%' OR plugin LIKE '%format_%'
ORDER BY plugin;" 2>&1

echo "=== RECENT MOODLE UPGRADES ==="
$DB -e "SELECT plugin, version, FROM_UNIXTIME(timemodified) AS modified
FROM mdl_config_plugins
WHERE timemodified > UNIX_TIMESTAMP(NOW()) - 30*86400
ORDER BY timemodified DESC LIMIT 20;" 2>&1

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-lp-v8.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-lp-v8-params.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/fix-lp-v8.sh",
  "chmod +x /tmp/fix-lp-v8.sh",
  "timeout 60 /tmp/fix-lp-v8.sh"
)} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 90 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

