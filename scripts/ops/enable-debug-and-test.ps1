$shellCmd = @'
echo "=== 1. Enable Moodle debug mode ==="
php -r '
define("CLI_SCRIPT", true);
require("/app/moodle/config.php");
$DB->set_field("config", "value", "38911", array("name" => "debug"));
$DB->set_field("config", "value", "1", array("name" => "debugdisplay"));
echo "Debug enabled\n";
' 2>&1

echo ""
echo "=== 2. Purge caches ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1

echo ""
echo "=== 3. Test course edit page with full output ==="
curl -s -m 60 -b "MoodleSession=test" http://localhost/course/edit.php?id=114 2>&1 | grep -i "error\|exception\|debug\|stack\|reading\|database\|dml\|fatal" | head -30

echo ""
echo "=== 4. Check Apache error log after request ==="
sleep 2
tail -20 /var/log/httpd/error_log 2>&1

echo "DONE"
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"

