# Debug what moodle_needs_upgrading() sees - compare stored hash vs computed hash
$phpCode = @'
<?php
define("CLI_SCRIPT", true);
define("ABORT_AFTER_CONFIG", true);
require("/app/moodle/config.php");

// Get stored values
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);

$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='version'");
$dbver = $stmt->fetchColumn();

$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='allversionshash'");
$dbhash = $stmt->fetchColumn();

$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='outagelessupgrade'");
$outflag = $stmt->fetchColumn();

$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='upgraderunning'");
$uprflag = $stmt->fetchColumn();

echo "DB version: $dbver\n";
echo "DB allversionshash: $dbhash\n";
echo "outagelessupgrade: " . ($outflag ?: "(not set)") . "\n";
echo "upgraderunning: " . ($uprflag ?: "(not set)") . "\n";

// Now compute the actual hash via core_component
// Need full Moodle bootstrap for this
echo "\n--- Now loading full Moodle to compute hash ---\n";
'@

$phpCode2 = @'
<?php
define("CLI_SCRIPT", true);
require("/app/moodle/config.php");
require_once($CFG->dirroot . "/lib/componentlib.class.php");

$computedHash = core_component::get_all_versions_hash();
echo "Computed allversionshash: $computedHash\n";

// Get stored hash
$storedHash = $CFG->allversionshash ?? "(not set)";
echo "Stored  allversionshash: $storedHash\n";

if ($computedHash === $storedHash) {
    echo "MATCH - moodle_needs_upgrading should return FALSE\n";
} else {
    echo "MISMATCH - moodle_needs_upgrading returns TRUE\n";
}
'@

# First do the quick DB check (no full bootstrap needed - less likely to hang)
$cmd1 = "echo '$phpCode' > /tmp/debug_hash1.php && timeout 30 php /tmp/debug_hash1.php 2>&1; echo EXIT_CODE=\$?"

$params = @{
    commands = @($cmd1)
}
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

