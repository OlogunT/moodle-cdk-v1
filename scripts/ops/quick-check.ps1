$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'qc.json'
@{ commands = @('ps aux | awk ''$8 ~ /D/ {print}'' || echo NONE; echo "---"; tail -10 /tmp/upgrade-log.txt 2>/dev/null || echo NOLOG; echo "---"; curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s" -m 10 http://localhost/login/index.php 2>&1') } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 30 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 20
$r = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent

