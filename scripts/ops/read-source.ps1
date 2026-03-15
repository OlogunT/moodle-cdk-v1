$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'read-src.json'

$bash = @'
pkill -9 -f "find_mm\|upgrade.php\|cron.php" 2>/dev/null || true
echo "=== Search for function ==="
grep -rn "function moodle_needs_upgrading" /app/moodle/lib/ 2>/dev/null || echo "Not in lib"
grep -rn "function moodle_needs_upgrading" /app/moodle/admin/ 2>/dev/null || echo "Not in admin"
echo "=== Search setuplib ==="
grep -n "moodle_needs_upgrading" /app/moodle/lib/setuplib.php 2>/dev/null || echo "Not in setuplib"
echo "=== Search all ==="
find /app/moodle -maxdepth 3 -name "*.php" -exec grep -l "function moodle_needs_upgrading" {} \; 2>/dev/null | head -5
echo "=== DONE ==="
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 30 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 15
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent

