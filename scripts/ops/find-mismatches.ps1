$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'find-mm.json'

$bash = @'
cat > /tmp/find_mismatches.php << 'PHPEOF'
<?php
define('CLI_SCRIPT', false);
define('NO_MOODLE_COOKIES', true);
define('ABORT_AFTER_CONFIG', true);
require('/app/moodle/config.php');
header('Content-Type: text/plain');

$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);

// Get DB plugin versions
$stmt = $dbh->query("SELECT plugin, version FROM mdl_config_plugins WHERE name='version'");
$dbplugins = [];
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $dbplugins[$row['plugin']] = $row['version'];
}

// Get disk plugin versions
$plugintypes = core_component::get_plugin_types();
$disk = [];
foreach ($plugintypes as $type => $typedir) {
    $plugins = core_component::get_plugin_list($type);
    foreach ($plugins as $plug => $plugdir) {
        $vf = $plugdir . '/version.php';
        $plugin = new stdClass(); $plugin->version = null;
        $module = $plugin;
        if (file_exists($vf)) { include($vf); }
        $ver = $plugin->version ?? $module->version ?? null;
        $key = $type . '_' . $plug;
        if ($ver !== null) $disk[$key] = $ver;
    }
}

echo "DB plugins: " . count($dbplugins) . "\n";
echo "Disk plugins: " . count($disk) . "\n\n";

// Find mismatches
$issues = 0;
foreach ($disk as $key => $ver) {
    $dbv = $dbplugins[$key] ?? null;
    if ($dbv === null) {
        echo "NEW (not in DB): $key = $ver\n";
        $issues++;
    } elseif ((float)$dbv < (float)$ver) {
        echo "UPGRADE NEEDED: $key db=$dbv disk=$ver\n";
        $issues++;
    }
}

// Check for DB entries without disk
foreach ($dbplugins as $key => $ver) {
    if (!isset($disk[$key])) {
        echo "ORPHAN (in DB not disk): $key = $ver\n";
    }
}

echo "\nTotal issues: $issues\n";

// Also check what moodle_needs_upgrading actually checks
require_once($CFG->libdir . '/upgradelib.php');
echo "\nmoodle_needs_upgrading: " . (moodle_needs_upgrading() ? 'YES' : 'NO') . "\n";

// Check core version comparison
$version = null;
require($CFG->dirroot . '/version.php');
$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='version'");
$dbver = $stmt->fetchColumn();
echo "Core: disk=$version db=$dbver match=" . ((float)$dbver >= (float)$version ? 'YES' : 'NO') . "\n";
PHPEOF

cp /tmp/find_mismatches.php /app/moodle/find_mismatches_9x7k.php
chown apache:apache /app/moodle/find_mismatches_9x7k.php
curl -s -m 60 http://localhost/find_mismatches_9x7k.php 2>&1
rm -f /app/moodle/find_mismatches_9x7k.php
echo ""
echo "=== DONE ==="
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 90 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 50
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

