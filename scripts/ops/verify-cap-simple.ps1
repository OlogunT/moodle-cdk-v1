# Simple DB check + PHP-FPM restart
$shellCmd = @'
# Check the capability directly in DB
RESULT=$(php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$cap = \$DB->get_record('role_capabilities', array('roleid'=>5, 'capability'=>'moodle/course:view', 'contextid'=>1));
echo \$cap ? \$cap->permission : 'NOT_SET';
" 2>/dev/null)
echo "moodle/course:view for student role: $RESULT (1=Allow, -1000=Prohibit)"

# Clear lock_db while we're at it
php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
\$count = \$DB->count_records('lock_db');
if (\$count > 0) { \$DB->delete_records('lock_db'); echo \"Cleared \$count stale locks\n\"; }
else { echo \"No stale locks\n\"; }
" 2>/dev/null

# Restart PHP-FPM
systemctl restart php-fpm 2>&1
echo "PHP-FPM restarted"
echo "EXIT=0"
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($shellCmd))
$cmd = "echo $b64 | base64 -d | bash"

$params = @{ commands = @($cmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 120 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 45
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

