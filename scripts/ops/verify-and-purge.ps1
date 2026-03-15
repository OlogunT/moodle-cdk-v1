# Check for any other missing tables and purge caches
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/ddllib.php');

$dbman = $DB->get_manager();

// Load core install.xml and check all tables
$xmlpath = $CFG->libdir . '/db/install.xml';
$xmldb = new xmldb_file($xmlpath);
$xmldb->loadXMLStructure();
$structure = $xmldb->getStructure();
$xmltables = $structure->getTables();

$missing = 0;
foreach ($xmltables as $xmltable) {
    if (!$dbman->table_exists($xmltable)) {
        $name = $xmltable->getName();
        echo "MISSING: $name -> CREATING\n";
        $dbman->create_table($xmltable);
        $missing++;
    }
}
echo "Fixed $missing missing core tables\n";
echo "Done\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/verify.php && php /tmp/verify.php 2>&1 && echo '---' && php /app/moodle/admin/cli/purge_caches.php 2>&1 && echo 'Caches purged' && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 120
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

