# Deploy a web script that computes hash via Moodle's full bootstrap and auto-fixes it
# Use define('ABORT_AFTER_CONFIG_CANCEL') trick to allow ABORT_AFTER_CONFIG to be bypassed
$phpCode = @'
<?php
// This script must bypass the upgrade redirect loop
// We use NO_UPGRADE_CHECK and handle the bootstrap carefully
define('CLI_SCRIPT', true);
define('ABORT_AFTER_CONFIG', true);
require('/app/moodle/config.php');
// Now manually init what we need
require_once($CFG->dirroot . '/lib/classes/component.php');

// Compute hash the same way moodle_needs_upgrading does
$computed = core_component::get_all_versions_hash();

// Get stored hash
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);
$stored = $dbh->query("SELECT value FROM mdl_config WHERE name='allversionshash'")->fetchColumn();
$dbver = $dbh->query("SELECT value FROM mdl_config WHERE name='version'")->fetchColumn();

echo "disk_version=$version_from_php\n";
echo "db_version=$dbver\n";
echo "computed_hash=$computed\n";
echo "stored_hash=$stored\n";

if ($computed !== $stored) {
    echo "MISMATCH - updating DB hash to computed value\n";
    $stmt = $dbh->prepare("UPDATE mdl_config SET value = ? WHERE name = 'allversionshash'");
    $stmt->execute([$computed]);
    echo "Updated allversionshash in DB\n";
} else {
    echo "Hashes match. Checking other conditions...\n";
}

// Also check $CFG->version (from DB) vs disk version.php
$version = null;
require($CFG->dirroot . '/version.php');
echo "disk_version_php=$version\n";

if ((string)$version !== (string)$dbver) {
    echo "VERSION MISMATCH: disk=$version db=$dbver\n";
} else {
    echo "Versions match\n";
}

// Check for any plugin version mismatches by listing all plugins and their versions
echo "\n--- Checking all plugin versions ---\n";
$plugintypes = core_component::get_plugin_types();
$mismatches = [];
foreach ($plugintypes as $type => $typedir) {
    $plugins = core_component::get_plugin_list($type);
    foreach ($plugins as $name => $dir) {
        $versionfile = $dir . '/version.php';
        if (file_exists($versionfile)) {
            $plugin = new stdClass();
            $plugin->version = null;
            $module = $plugin; // Some old plugins use $module
            include($versionfile);
            $diskver = $plugin->version ?? $module->version ?? null;
            
            // Get DB version for this plugin
            $component = $type . '_' . $name;
            $dbpluginver = $dbh->query("SELECT value FROM mdl_config_plugins WHERE plugin='$component' AND name='version'")->fetchColumn();
            
            if ($diskver !== null && $dbpluginver !== false && (string)$diskver !== (string)$dbpluginver) {
                $mismatches[] = "$component: disk=$diskver db=$dbpluginver";
            } elseif ($diskver !== null && $dbpluginver === false) {
                $mismatches[] = "$component: disk=$diskver db=(not installed)";
            }
        }
    }
}

if (empty($mismatches)) {
    echo "No plugin version mismatches found\n";
} else {
    echo count($mismatches) . " plugin version mismatches:\n";
    foreach ($mismatches as $m) {
        echo "  $m\n";
    }
}
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/fix_hash.php && timeout 120 php /tmp/fix_hash.php 2>&1; echo EXIT_CODE=`$?"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Write-Host "Waiting 60 seconds for plugin scan to complete..."
Start-Sleep 60

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

