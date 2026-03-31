#!/usr/bin/env pwsh
# Nuclear restart: kill ALL stuck processes, clear NFS locks, restart services on both instances
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1'
)
$ErrorActionPreference = 'Stop'
$instances = @('i-0c386871e2eb20f71', 'i-04aa12a6aa64b6e66')

$bash = @'
#!/bin/bash
echo "=== INSTANCE: $(hostname) $(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null) ==="

echo "--- Kill ALL apache/php processes ---"
pkill -9 -u apache 2>/dev/null && echo "Killed apache procs" || echo "No apache procs"
pkill -9 -f "php" 2>/dev/null && echo "Killed php procs" || echo "No php procs"
pkill -9 -f "find /data" 2>/dev/null && echo "Killed find procs" || echo "No find procs"
sleep 2

echo "--- config.php status ---"
php -l /app/moodle/config.php 2>&1

echo "--- lock_factory in config ---"
grep -n "lock_factory" /app/moodle/config.php || echo "MISSING - adding now"
if ! grep -q "lock_factory" /app/moodle/config.php; then
    sed -i "s|require_once(__DIR__ . '/lib/setup.php');|\$CFG->lock_factory = 'core\\\\lock\\\\db_record_lock_factory';\nrequire_once(__DIR__ . '/lib/setup.php');|" /app/moodle/config.php
    grep -n "lock_factory" /app/moodle/config.php
fi

echo "--- Clear lock dirs (fast) ---"
rm -f /data/moodledata/lock/* 2>/dev/null
rm -f /data/moodledata/temp/lock/* 2>/dev/null
echo "Lock dirs cleared"

echo "--- Restart PHP-FPM ---"
systemctl restart php-fpm 2>&1
echo "PHP-FPM done"

echo "--- Restart httpd ---"
systemctl restart httpd 2>&1
echo "httpd done"

sleep 5

echo "--- Services status ---"
systemctl is-active httpd php-fpm

echo "--- Local test ---"
curl -s -o /dev/null -w "HTTP:%{http_code}" --max-time 10 http://localhost/ 2>&1
echo ""
echo "DONE $(hostname)"
'@

$pf = Join-Path $env:TEMP 'nuclear-restart.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8
Write-Host "Params file: $pf"

$cmdIds = @()
foreach ($inst in $instances) {
    Write-Host "Sending to $inst ..."
    $id = ((aws --profile $Profile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 120 `
        --query 'Command.CommandId' --output text 2>&1)).Trim()
    Write-Host "  CMD: $id"
    $cmdIds += [pscustomobject]@{ Instance=$inst; CmdId=$id }
    Start-Sleep 2
}

Write-Host "Waiting 45s for commands to complete..."
Start-Sleep 45

foreach ($c in $cmdIds) {
    Write-Host "`n=== Results for $($c.Instance) ==="
    $r = aws --profile $Profile --region $Region ssm get-command-invocation `
        --command-id $c.CmdId --instance-id $c.Instance `
        --query '{S:Status,RC:ResponseCode,O:StandardOutputContent,E:StandardErrorContent}' `
        --output json 2>&1 | ConvertFrom-Json
    Write-Host "Status: $($r.S) RC: $($r.RC)"
    Write-Host $r.O
    if ($r.E) { Write-Host "STDERR: $($r.E)" }
}

