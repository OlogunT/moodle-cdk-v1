# Warmup cache then test admin page with longer timeout
$shellCmd = @'
echo "=== Warmup request 1 (homepage) ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 120 https://elearning.tsin.ca/ 2>&1
echo ""
echo "=== Warmup request 2 (login page) ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 120 https://elearning.tsin.ca/login/index.php 2>&1
echo ""
echo "=== Test admin page (120s timeout) ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s URL: %{url_effective}\n" -L -m 120 https://elearning.tsin.ca/admin/index.php 2>&1
echo ""
echo "=== Check PHP-FPM processes ==="
ps aux | grep php-fpm | grep -v grep | wc -l
echo "workers active"
echo ""
echo "=== Check localcache status ==="
ls -la /data/moodledata/localcache/ 2>/dev/null | head -20
echo "DONE"
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 600 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Write-Host "Waiting 180 seconds for warmup + admin test..."
Start-Sleep 180

$result = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

