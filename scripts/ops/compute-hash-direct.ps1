# Compute hash without full Moodle bootstrap - use ABORT_AFTER_CONFIG + manually load core_component
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
define('ABORT_AFTER_CONFIG', true);
require('/app/moodle/config.php');
require_once($CFG->dirroot . '/lib/classes/component.php');
$computed = core_component::get_all_versions_hash();
echo "computed_hash=$computed\n";
// Also get stored hash from DB
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);
$stored = $dbh->query("SELECT value FROM mdl_config WHERE name='allversionshash'")->fetchColumn();
echo "stored_hash=$stored\n";
echo "match=" . ($computed === $stored ? "YES" : "NO") . "\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/compute_hash.php && timeout 60 php /tmp/compute_hash.php 2>&1; echo EXIT_CODE=`$?"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 90 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 30

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

