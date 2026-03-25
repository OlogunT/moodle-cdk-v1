# Install the cron job for stale lock cleanup (script already deployed)
$setupScript = @'
#!/bin/bash
# Create a helper script to install the cron
cat > /tmp/install_cron.sh << 'CRONEOF'
#!/bin/bash
CRONLINE="*/5 * * * * php /app/moodle/local/cleanup_stale_locks.php > /dev/null 2>&1"
# Remove old entry if exists, then add new one
crontab -l 2>/dev/null | grep -v "cleanup_stale_locks" > /tmp/crontab_new
echo "$CRONLINE" >> /tmp/crontab_new
crontab /tmp/crontab_new
rm -f /tmp/crontab_new
echo "Cron installed"
crontab -l | grep cleanup
CRONEOF
chmod +x /tmp/install_cron.sh
bash /tmp/install_cron.sh 2>&1

echo "=== Verify PHP script ==="
head -5 /app/moodle/local/cleanup_stale_locks.php
echo "..."
echo "=== Test run ==="
php /app/moodle/local/cleanup_stale_locks.php 2>&1
echo "Exit: $?"
echo "EXIT=0"
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($setupScript))
$shellCmd = "echo $b64 | base64 -d > /tmp/setup_cron.sh && bash /tmp/setup_cron.sh 2>&1"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 60
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

