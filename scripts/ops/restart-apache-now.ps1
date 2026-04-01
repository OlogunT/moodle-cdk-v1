#!/usr/bin/env pwsh
Param(
  [string]$Profile  = 'tsin-account',
  [string]$Region   = 'ca-central-1',
  [string]$Instance = 'i-0c386871e2eb20f71'
)
$ErrorActionPreference = 'Stop'

$bash = @'
#!/bin/bash
echo "=== Web server status ==="
systemctl status httpd --no-pager 2>&1 | tail -20 || true
systemctl status nginx --no-pager 2>&1 | tail -10 || true
systemctl status php-fpm --no-pager 2>&1 | tail -10 || true

echo ""
echo "=== Listening ports ==="
ss -tlnp 2>/dev/null | grep -E ':80|:443|:9000' || netstat -tlnp 2>/dev/null | grep -E ':80|:443|:9000' || echo "ss/netstat failed"

echo ""
echo "=== Restart services ==="
systemctl restart httpd 2>&1 && echo "httpd restarted" || echo "httpd restart failed"
systemctl restart php-fpm 2>&1 && echo "php-fpm restarted" || echo "php-fpm restart failed"

sleep 5

echo ""
echo "=== Check ports after restart ==="
ss -tlnp 2>/dev/null | grep -E ':80|:443|:9000' || true

echo ""
echo "=== Local HTTP test ==="
curl -s -o /dev/null -w "localhost HTTP:%{http_code}" --max-time 10 http://localhost/ 2>&1
echo ""
curl -s -o /dev/null -w "localhost-login HTTP:%{http_code}" --max-time 10 http://localhost/login/index.php 2>&1
echo ""
echo "DONE"
'@

$pf = Join-Path $env:TEMP 'restart-apache-now.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8
Write-Host "Sending SSM to $Instance ..."

$cmdId = ((aws --profile $Profile --region $Region ssm send-command `
    --instance-ids $Instance `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text 2>&1)).Trim()
Write-Host "CommandId: $cmdId"

if ($cmdId -notmatch '^[0-9a-f\-]{36}$') { Write-Host "ERROR: $cmdId"; exit 1 }

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

