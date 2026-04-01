# Find communication install.xml and create missing table
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/upgradelib.php');
require_once($CFG->libdir . '/ddllib.php');

$dbman = $DB->get_manager();

// Check install.xml for communication
$xmlpath = $CFG->dirroot . '/communication/db/install.xml';
echo "install.xml exists: " . (file_exists($xmlpath) ? "YES" : "NO") . "\n";

if (file_exists($xmlpath)) {
    echo "Path: $xmlpath\n";
    // Load and install tables from install.xml
    $dbman->install_from_xmldb_file($xmlpath);
    echo "Tables installed from communication install.xml\n";
}

// Check for communication provider tables
$providerpath = $CFG->dirroot . '/communication/provider';
if (is_dir($providerpath)) {
    $providers = scandir($providerpath);
    foreach ($providers as $p) {
        if ($p === '.' || $p === '..') continue;
        $pxml = "$providerpath/$p/db/install.xml";
        if (file_exists($pxml)) {
            echo "Installing tables for provider: $p\n";
            $dbman->install_from_xmldb_file($pxml);
        }
    }
}

// Verify
$tables = $DB->get_tables();
$has_comm = in_array('communication', $tables);
echo "\ncommunication table now exists: " . ($has_comm ? "YES" : "NO") . "\n";

// List all communication related tables
foreach ($tables as $t) {
    if (strpos($t, 'communication') !== false) {
        echo "Table: $t\n";
    }
}
echo "Done\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_comm.php && php /tmp/fix_comm.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 40
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

