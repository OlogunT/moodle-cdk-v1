# Use base64 to avoid all escaping issues
$phpCode = @'
<?php
define("CLI_SCRIPT", true);
define("ABORT_AFTER_CONFIG", true);
require("/app/moodle/config.php");
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);
$rows = $dbh->query("SELECT name, value FROM mdl_config WHERE name IN ('version','allversionshash','outagelessupgrade','upgraderunning','adminsetuppending')")->fetchAll(PDO::FETCH_KEY_PAIR);
foreach($rows as $k=>$v) echo "$k = $v\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))

$shellCmd = "echo $b64 | base64 -d > /tmp/dbg.php && timeout 30 php /tmp/dbg.php 2>&1"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 15

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

