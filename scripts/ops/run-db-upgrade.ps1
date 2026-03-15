# Run Moodle database upgrade via CLI
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
// Check if communication table exists
$tables = $DB->get_tables();
$has_comm = in_array('communication', $tables);
echo "communication table exists: " . ($has_comm ? "YES" : "NO") . "\n";
echo "Moodle version (disk): " . $CFG->version . "\n";
$dbver = $DB->get_field('config', 'value', array('name' => 'version'));
echo "Moodle version (db): " . $dbver . "\n";
if ($CFG->version > $dbver) {
    echo "UPGRADE NEEDED: disk=$CFG->version > db=$dbver\n";
} else {
    echo "Versions match\n";
}
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/check_upgrade.php && php /tmp/check_upgrade.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 120 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 30
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

