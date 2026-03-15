# Create just the missing communication table from core install.xml
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/upgradelib.php');
require_once($CFG->libdir . '/ddllib.php');

$dbman = $DB->get_manager();

// Check which communication-related tables exist
$tables = $DB->get_tables();
echo "Existing tables with 'communication':\n";
foreach ($tables as $t) {
    if (strpos($t, 'communication') !== false) {
        echo "  EXISTS: $t\n";
    }
}

// Load core install.xml
$xmlpath = $CFG->libdir . '/db/install.xml';
echo "\nCore install.xml: $xmlpath\n";
$xmldb = new xmldb_file($xmlpath);
$xmldb->loadXMLStructure();
$structure = $xmldb->getStructure();
$xmltables = $structure->getTables();

echo "\nLooking for communication tables in core install.xml:\n";
foreach ($xmltables as $xmltable) {
    $name = $xmltable->getName();
    if (strpos($name, 'communication') !== false) {
        echo "  FOUND in XML: $name\n";
        if (!$dbman->table_exists($xmltable)) {
            echo "    -> CREATING table $name\n";
            $dbman->create_table($xmltable);
            echo "    -> CREATED\n";
        } else {
            echo "    -> already exists in DB\n";
        }
    }
}

// Verify
echo "\nVerification:\n";
$has = $dbman->table_exists(new xmldb_table('communication'));
echo "communication table exists: " . ($has ? "YES" : "NO") . "\n";
echo "Done\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/create_comm.php && php /tmp/create_comm.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 45
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

