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

echo "=== MOODLE CORE VERSION (config vs DB) ==="
echo "config.php version:"
grep -m1 'version.*=' "$CONFIG" | head -1
echo "DB version:"
$DB -sN -e "SELECT CONCAT(name,'=',value) FROM mdl_config WHERE name IN ('version','release','upgraderunning','allversionshash') ORDER BY name;" 2>&1

echo "=== PLUGIN VERSION MISMATCHES (disk vs DB) ==="
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once('/app/moodle/lib/componentlib.class.php');
\$pluginman = core_plugin_manager::instance();
\$plugins = \$pluginman->get_plugins();
foreach (\$plugins as \$type => \$list) {
  foreach (\$list as \$name => \$info) {
    if (\$info->get_status() !== core_plugin_manager::PLUGIN_STATUS_UPTODATE) {
      echo \$type.'_'.\$name.' status='.\$info->get_status().' disk='.\$info->versiondisk.' db='.\$info->versiondb.PHP_EOL;
    }
  }
}
echo 'Plugin check done'.PHP_EOL;
" 2>&1

echo "=== MOODLE allversionshash ==="
$DB -sN -e "SELECT value FROM mdl_config WHERE name='allversionshash';" 2>&1

echo "=== OPCACHE STATUS ==="
php -r "
if (function_exists('opcache_get_status')) {
  \$s = opcache_get_status();
  echo 'enabled: '.(\$s['opcache_enabled']?'yes':'no').PHP_EOL;
  echo 'cached_scripts: '.\$s['opcache_statistics']['num_cached_scripts'].PHP_EOL;
  echo 'hits: '.\$s['opcache_statistics']['hits'].PHP_EOL;
  echo 'misses: '.\$s['opcache_statistics']['misses'].PHP_EOL;
} else { echo 'OPcache not available'.PHP_EOL; }
" 2>&1

echo "=== MOODLE DEBUG SETTINGS ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('debug','debugdisplay','perfdebug','debugpageinfo');" 2>&1

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'diagnose-slow-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Start-Sleep 25
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

