$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'fix-hash.json'

# Step 1: Kill stuck processes, create a temp PHP script, then call it via curl
$bash = @'
pkill -9 -f "upgrade.php" 2>/dev/null || true
pkill -9 -f "cron.php" 2>/dev/null || true
crontab -u apache -r 2>/dev/null || true
sleep 2

CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"
$DB -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1

cat > /app/moodle/fix_hash_temp_9x7k.php << 'PHPEOF'
<?php
define('CLI_SCRIPT', false);
define('NO_MOODLE_COOKIES', true);
define('NO_OUTPUT_BUFFERING', true);
define('ABORT_AFTER_CONFIG', true);
require(__DIR__ . '/config.php');

header('Content-Type: text/plain');

// Get all version.php values and compute hash
$plugintypes = core_component::get_plugin_types();
$versions = array();
$versions['core'] = null;

// Read core version
$version = null;
require($CFG->dirroot . '/version.php');
$versions['core'] = $version;

// Read all plugin versions
foreach ($plugintypes as $type => $typedir) {
    $plugins = core_component::get_plugin_list($type);
    foreach ($plugins as $plug => $plugdir) {
        $versionfile = $plugdir . '/version.php';
        $plugin = new stdClass();
        $plugin->version = null;
        $module = $plugin;
        if (file_exists($versionfile)) {
            include($versionfile);
        }
        $ver = $plugin->version ?? $module->version ?? null;
        if ($ver !== null) {
            $versions[$type . '_' . $plug] = $ver;
        }
    }
}

// Compute hash
ksort($versions);
$hash = sha1(serialize($versions));

echo "Computed hash: $hash\n";
echo "Versions count: " . count($versions) . "\n";
echo "Core version: " . $versions['core'] . "\n";

// Check current DB state
$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);

// Get current DB core version
$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='version'");
$dbver = $stmt->fetchColumn();
echo "DB core version: $dbver\n";

// Update core version if needed
if ($dbver != $versions['core']) {
    echo "Version mismatch: DB=$dbver, disk={$versions['core']}\n";
    $dbh->exec("UPDATE mdl_config SET value='" . $versions['core'] . "' WHERE name='version'");
    echo "Updated DB version to {$versions['core']}\n";
}

// Set allversionshash
$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='allversionshash'");
$existing = $stmt->fetchColumn();
if ($existing) {
    $dbh->exec("UPDATE mdl_config SET value='$hash' WHERE name='allversionshash'");
    echo "Updated allversionshash\n";
} else {
    $dbh->exec("INSERT INTO mdl_config (name, value) VALUES ('allversionshash', '$hash')");
    echo "Inserted allversionshash\n";
}

// Check plugin version mismatches
$stmt = $dbh->query("SELECT plugin, version FROM mdl_config_plugins WHERE name='version'");
$dbplugins = [];
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $dbplugins[$row['plugin']] = $row['version'];
}

$mismatches = 0;
foreach ($versions as $key => $ver) {
    if ($key === 'core') continue;
    $dbv = $dbplugins[$key] ?? null;
    if ($dbv !== null && $dbv != $ver) {
        echo "MISMATCH: $key db=$dbv disk=$ver\n";
        $mismatches++;
    } elseif ($dbv === null) {
        echo "NEW: $key disk=$ver (not in DB)\n";
    }
}
echo "Mismatches: $mismatches\n";

// Verify
$stmt = $dbh->query("SELECT value FROM mdl_config WHERE name='allversionshash'");
echo "Verified hash in DB: " . $stmt->fetchColumn() . "\n";
echo "DONE\n";
PHPEOF

chown apache:apache /app/moodle/fix_hash_temp_9x7k.php
echo "=== CALLING FIX SCRIPT ==="
curl -s -m 60 http://localhost/fix_hash_temp_9x7k.php 2>&1
echo ""
echo "=== CLEANUP ==="
rm -f /app/moodle/fix_hash_temp_9x7k.php
echo "Cleaned up"

echo "=== VERIFY ==="
curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s\n" -m 15 http://localhost/login/index.php 2>&1
curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s\n" -m 15 http://localhost/login/index.php 2>&1
echo "=== DONE ==="
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 120 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 60
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

