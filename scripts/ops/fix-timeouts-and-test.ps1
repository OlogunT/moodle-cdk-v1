# Increase PHP and Apache timeouts, then test admin page
$shellCmd = @'
echo "=== Current PHP max_execution_time ==="
php -r "echo ini_get('max_execution_time').PHP_EOL;"

echo "=== Updating PHP timeout to 120s ==="
# Find php.ini
PHP_INI=$(php -r "echo php_ini_loaded_file();")
echo "PHP ini: $PHP_INI"
sed -i 's/max_execution_time = .*/max_execution_time = 120/' "$PHP_INI" 2>/dev/null
echo "Updated max_execution_time"

echo "=== Updating Apache timeout ==="
grep -r "Timeout" /etc/httpd/conf/httpd.conf 2>/dev/null || echo "No Timeout in httpd.conf"
# Add or update Timeout directive
if grep -q "^Timeout " /etc/httpd/conf/httpd.conf; then
    sed -i 's/^Timeout .*/Timeout 120/' /etc/httpd/conf/httpd.conf
else
    echo "Timeout 120" >> /etc/httpd/conf/httpd.conf
fi
echo "Apache timeout set to 120s"

echo "=== Restarting services ==="
systemctl restart php-fpm
systemctl restart httpd
echo "Services restarted"

echo "=== Testing admin page (120s timeout) ==="
curl -s -o /dev/null -w "HTTP: %{http_code} Time: %{time_total}s URL: %{url_effective}\n" -L -m 120 https://elearning.tsin.ca/admin/index.php 2>&1

echo "=== Done ==="
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
Write-Host "Waiting 150 seconds..."
Start-Sleep 150

$result = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

