# Place a web-accessible PHP file to compute the hash, then curl it
$phpCode = @'
<?php
define('NO_MOODLE_COOKIES', true);
define('NO_UPGRADE_CHECK', true);
require(__DIR__ . '/config.php');
header('Content-Type: text/plain');
$computed = core_component::get_all_versions_hash();
$stored = $CFG->allversionshash ?? '(not set)';
echo "computed=$computed\n";
echo "stored=$stored\n";
echo "match=" . ($computed === $stored ? "YES" : "NO") . "\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))

$shellCmd = "echo $b64 | base64 -d > /app/moodle/debug_hash_check.php && curl -s -m 30 http://localhost/debug_hash_check.php 2>&1; echo; echo EXIT=`$?"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 20

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

