$ErrorActionPreference = 'Stop'
$bash = 'tail -50 /tmp/upgrade-log.txt 2>/dev/null || echo NO_LOG; echo "---PROCS---"; ps aux | grep -E "(upgrade|cron)\.php" | grep -v grep; echo "---DSTATE---"; ps aux | awk ''$8 ~ /D/ {print}'''
$paramsFile = Join-Path $env:TEMP 'chk-upg.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8
$cmdId = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$paramsFile" --timeout-seconds 15 --query 'Command.CommandId' --output text).Trim()
Write-Host "CMD: $cmdId"
Start-Sleep 12
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation --command-id $cmdId --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "Status: $($r.Status)"
Write-Host $r.StandardOutputContent

