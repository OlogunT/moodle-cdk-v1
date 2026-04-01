# Full debug - check ALL conditions that could trigger upgrade redirect
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
define('ABORT_AFTER_CONFIG', true);
require('/app/moodle/config.php');

// Get disk version
$version = null;
$release = null;
require($CFG->dirroot . '/version.php');
echo "disk_version=$version\n";
echo "disk_release=$release\n";

// Get DB values
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);
$rows = $dbh->query("SELECT name, value FROM mdl_config WHERE name IN ('version','allversionshash','outagelessupgrade','upgraderunning','adminsetuppending')")->fetchAll(PDO::FETCH_KEY_PAIR);
foreach($rows as $k=>$v) echo "db_$k=$v\n";

// Check is_major_upgrade_required logic
echo "cfg_version=" . ($CFG->version ?? '(not set)') . "\n";

// Compute hash
require_once($CFG->dirroot . '/lib/classes/component.php');
$computed = core_component::get_all_versions_hash();
echo "computed_hash=$computed\n";

// Check version comparison
$dbversion = $rows['version'] ?? '';
echo "version_compare=" . ($version > (float)$dbversion ? "DISK_NEWER" : ($version == (float)$dbversion ? "EQUAL" : "DB_NEWER")) . "\n";

// Check if admin setup pending
echo "adminsetuppending=" . (isset($rows['adminsetuppending']) ? $rows['adminsetuppending'] : "(not set)") . "\n";

// Check if there's a theme designer mode or other debug flags
echo "themedesignermode=" . ($CFG->themedesignermode ?? '(not set)') . "\n";
echo "upgradekey=" . (isset($CFG->upgradekey) ? "SET" : "(not set)") . "\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/debug_full.php && timeout 60 php /tmp/debug_full.php 2>&1; echo EXIT_CODE=`$?"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 90 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 25

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

