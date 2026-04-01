$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'debug-upg.json'

$bash = @'
echo "=== moodle_needs_upgrading source ==="
grep -n "function moodle_needs_upgrading" /app/moodle/lib/upgradelib.php
grep -A 50 "function moodle_needs_upgrading" /app/moodle/lib/upgradelib.php | head -60

echo "=== END ==="
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 30 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 12
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

