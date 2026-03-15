$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'find-mm2.json'

$bash = @'
cat > /app/moodle/find_mm_9x7k.php << 'PHPEOF'
<?php
error_reporting(E_ALL);
ini_set('display_errors', 1);
define('CLI_SCRIPT', false);
define('NO_MOODLE_COOKIES', true);
define('ABORT_AFTER_CONFIG', true);
require(__DIR__ . '/config.php');
header('Content-Type: text/plain');

echo "START\n";

$dbh = new PDO("mysql:host={$CFG->dbhost};dbname={$CFG->dbname}", $CFG->dbuser, $CFG->dbpass);

// DB plugin versions
$stmt = $dbh->query("SELECT plugin, version FROM mdl_config_plugins WHERE name='version'");
$dbplugins = [];
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $dbplugins[$row['plugin']] = $row['version'];
}
echo "DB plugins: " . count($dbplugins) . "\n";

// Disk plugin versions
$plugintypes = core_component::get_plugin_types();
$issues = 0;
foreach ($plugintypes as $type => $typedir) {
    $plugins = core_component::get_plugin_list($type);
    foreach ($plugins as $plug => $plugdir) {
        $vf = $plugdir . '/version.php';
        $plugin = new stdClass(); $plugin->version = null;
        $module = $plugin;
        if (file_exists($vf)) { include($vf); }
        $ver = $plugin->version ?? $module->version ?? null;
        $key = $type . '_' . $plug;
        if ($ver === null) continue;
        $dbv = $dbplugins[$key] ?? null;
        if ($dbv === null) {
            echo "NEW: $key=$ver\n";
            $issues++;
        } elseif ((float)$dbv < (float)$ver) {
            echo "UPG: $key db=$dbv disk=$ver\n";
            $issues++;
        }
    }
}
echo "Issues: $issues\n";

// Core check
$version = null;
require($CFG->dirroot . '/version.php');
$stmt2 = $dbh->query("SELECT value FROM mdl_config WHERE name='version'");
$dbver = $stmt2->fetchColumn();
echo "Core: disk=$version db=$dbver\n";

echo "DONE\n";
PHPEOF

chown apache:apache /app/moodle/find_mm_9x7k.php
echo "=== CURL OUTPUT ==="
curl -sv -m 60 http://localhost/find_mm_9x7k.php 2>&1
echo ""
echo "=== PHP ERROR LOG ==="
tail -5 /var/log/php-fpm/www-error.log 2>/dev/null
echo "=== CLEANUP ==="
rm -f /app/moodle/find_mm_9x7k.php
echo "DONE"
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 90 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 40
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

