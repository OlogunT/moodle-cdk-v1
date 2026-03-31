#!/usr/bin/env pwsh
# EMERGENCY: Fix broken config.php (parse error on lock_factory line) and restart PHP-FPM
Param(
  [string]$Profile  = 'tsin-account',
  [string]$Region   = 'ca-central-1',
  [string]$Instance = 'i-0c386871e2eb20f71'
)
$ErrorActionPreference = 'Stop'

# Minimal bash: just remove bad lock_factory lines and restart PHP-FPM
$bash = @'
#!/bin/bash
CONFIG="/app/moodle/config.php"
echo "=== Before fix ==="
grep -n "lock_factory" "$CONFIG" || echo "no lock_factory lines"

echo "=== Removing all lock_factory lines ==="
sed -i '/lock_factory/d' "$CONFIG"
echo "Removed"

echo "=== Adding clean lock_factory line ==="
sed -i "s|require_once(__DIR__ . '/lib/setup.php');|\$CFG->lock_factory = 'core\\\\lock\\\\db_record_lock_factory';\nrequire_once(__DIR__ . '/lib/setup.php');|" "$CONFIG"

echo "=== After fix ==="
grep -n "lock_factory" "$CONFIG" || echo "no lock_factory lines"

echo "=== Syntax check ==="
php -l "$CONFIG" 2>&1

echo "=== Kill all stuck PHP workers ==="
pkill -9 -u apache 2>/dev/null || true
sleep 2

echo "=== Restart PHP-FPM ==="
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"

sleep 3
echo "=== Test ==="
curl -s -o /dev/null -w "HTTP:%{http_code}" --max-time 10 http://localhost/ 2>&1
echo ""
echo "DONE"
'@

$pf = Join-Path $env:TEMP 'emergency-config-fix.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8
Write-Host "Sending SSM to $Instance ..."

$cmdId = ((aws --profile $Profile --region $Region ssm send-command `
    --instance-ids $Instance `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text 2>&1)).Trim()
Write-Host "CommandId: $cmdId"

if ($cmdId -notmatch '^[0-9a-f\-]{36}$') {
    Write-Host "ERROR: bad command ID: $cmdId"
    exit 1
}

Write-Host "Waiting 30s..."
Start-Sleep 30

for ($i = 1; $i -le 5; $i++) {
    $r = aws --profile $Profile --region $Region ssm get-command-invocation `
        --command-id $cmdId --instance-id $Instance `
        --query '{S:Status,RC:ResponseCode,O:StandardOutputContent,E:StandardErrorContent}' `
        --output json 2>&1 | ConvertFrom-Json
    Write-Host "[$i] Status: $($r.S) RC: $($r.RC)"
    if ($r.S -in 'Success','Failed','Cancelled','TimedOut') {
        Write-Host $r.O
        if ($r.E) { Write-Host "STDERR: $($r.E)" }
        break
    }
    Start-Sleep 15
}

