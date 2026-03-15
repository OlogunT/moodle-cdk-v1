$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'find-mm3.json'

$bash = @'
cat > /tmp/find_mm.php << 'PHPEOF'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/upgradelib.php');

// Check what moodle_needs_upgrading looks at
$version = null;
require($CFG->dirroot . '/version.php');
echo "Disk core: $version\n";

// DB core version
$dbversion = $DB->get_field('config', 'value', array('name' => 'version'));
echo "DB core: $dbversion\n";
echo "Core needs upgrade: " . ((float)$version > (float)$dbversion ? 'YES' : 'NO') . "\n\n";

// Check allversionshash
$dbhash = $DB->get_field('config', 'value', array('name' => 'allversionshash'));
$calchash = core_component::get_all_versions_hash();
echo "DB hash: $dbhash\n";
echo "Calc hash: $calchash\n";
echo "Hash match: " . ($dbhash === $calchash ? 'YES' : 'NO') . "\n\n";

// If hash doesn't match, find what changed
if ($dbhash !== $calchash) {
    echo "Hash mismatch - finding differences...\n";
    $plugintypes = core_component::get_plugin_types();
    $issues = 0;
    foreach ($plugintypes as $type => $typedir) {
        $plugins = core_component::get_plugin_list($type);
        foreach ($plugins as $plug => $plugdir) {
            $key = $type . '_' . $plug;
            $diskver = get_component_version($key);
            $dbver = $DB->get_field('config_plugins', 'version', array('plugin' => $key, 'name' => 'version'));
            if ($diskver === false || $diskver === null) continue;
            if ($dbver === false) {
                echo "NEW: $key disk=$diskver\n";
                $issues++;
            } elseif ((float)$diskver > (float)$dbver) {
                echo "UPG: $key db=$dbver disk=$diskver\n";
                $issues++;
            }
        }
    }
    echo "Issues: $issues\n";
}

echo "\nmoodle_needs_upgrading: " . (moodle_needs_upgrading() ? 'YES' : 'NO') . "\n";
PHPEOF

timeout 45 php /tmp/find_mm.php 2>&1
echo "Exit: $?"
rm -f /tmp/find_mm.php
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 90 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 55
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

