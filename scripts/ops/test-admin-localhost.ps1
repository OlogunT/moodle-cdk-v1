# Test admin page from localhost (bypass ALB) and check for CloudFront
$shellCmd = @'
echo "=== Test admin from localhost (bypass ALB) ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 120 http://localhost/admin/index.php 2>&1
echo ""
echo "=== Check Apache ProxyTimeout ==="
grep -ri "timeout\|proxy" /etc/httpd/conf.d/*.conf 2>/dev/null | head -20
echo ""
echo "=== Check PHP-FPM pool timeout ==="
grep -ri "request_terminate_timeout\|pm\." /etc/php-fpm.d/*.conf 2>/dev/null | head -20
echo ""
echo "=== Check if there is a reverse proxy config ==="
grep -ri "proxy" /etc/httpd/conf/httpd.conf 2>/dev/null | head -10
echo "DONE"
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 150

$result = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

