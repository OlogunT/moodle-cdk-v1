# Speed up admin page by pre-building caches and running purge/upgrade via CLI
$shellCmd = @'
echo "=== 1. Purge caches via CLI ==="
timeout 120 php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "EXIT=$?"

echo ""
echo "=== 2. Check upgrade status ==="
timeout 120 php /app/moodle/admin/cli/checks.php 2>&1
echo "EXIT=$?"

echo ""
echo "=== 3. Try admin/cli/upgrade.php --non-interactive ==="
timeout 120 php /app/moodle/admin/cli/upgrade.php --non-interactive 2>&1
echo "EXIT=$?"

echo ""
echo "=== 4. Rebuild course cache ==="
timeout 60 php /app/moodle/admin/cli/fix_course_sequence.php 2>&1
echo "EXIT=$?"

echo ""
echo "=== 5. Restart PHP-FPM ==="
systemctl restart php-fpm
echo "PHP-FPM restarted"

echo ""
echo "=== 6. Warmup homepage ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 30 http://localhost/ 2>&1

echo ""
echo "=== 7. Test admin from localhost ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s\n" -m 120 http://localhost/admin/index.php 2>&1

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

