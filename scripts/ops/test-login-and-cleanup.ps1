# Test login and clean up debug files
$shellCmd = @'
echo "=== Testing login page ==="
curl -s -o /dev/null -w "HTTP: %{http_code}\nTime: %{time_total}s\n" https://elearning.tsin.ca/login/index.php 2>&1
echo ""
echo "=== Clean up debug files from webroot ==="
rm -f /app/moodle/debug_hash_check.php 2>/dev/null && echo "Removed debug_hash_check.php" || echo "debug_hash_check.php not found"
rm -f /app/moodle/debug_*.php 2>/dev/null
rm -f /tmp/debug_hash*.php /tmp/dbg.php /tmp/compute_hash.php /tmp/fix_hash.php /tmp/debug_full.php 2>/dev/null
echo "Cleaned up temp files"
echo ""
echo "=== Test admin page (should not redirect to upgrade) ==="
curl -s -o /dev/null -w "URL: %{url_effective}\nHTTP: %{http_code}\nRedirects: %{num_redirects}\n" -L https://elearning.tsin.ca/admin/index.php 2>&1
echo ""
echo "=== Check site response time ==="
curl -s -o /dev/null -w "Request 1: %{http_code} in %{time_total}s\n" https://elearning.tsin.ca/ 2>&1
curl -s -o /dev/null -w "Request 2: %{http_code} in %{time_total}s\n" https://elearning.tsin.ca/ 2>&1
curl -s -o /dev/null -w "Request 3: %{http_code} in %{time_total}s\n" https://elearning.tsin.ca/ 2>&1
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 120 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 40

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

