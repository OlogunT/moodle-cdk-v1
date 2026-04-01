$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'debug-upg2.json'

$bash = @'
echo "=== Search for moodle_needs_upgrading ==="
grep -rn "function moodle_needs_upgrading" /app/moodle/lib/ 2>/dev/null | head -5

echo "=== Detailed check ==="
timeout 30 php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once(\$CFG->libdir . '/upgradelib.php');

// Core version check
\$version = null;
require(\$CFG->dirroot . '/version.php');
\$dbver = \$DB->get_field('config', 'value', array('name' => 'version'));
echo \"1. Core: disk=\$version db=\$dbver needs_upg=\" . ((float)\$version > (float)\$dbver ? 'Y' : 'N') . \"\n\";

// Hash check
\$dbhash = \$DB->get_field('config', 'value', array('name' => 'allversionshash'));
\$calchash = core_component::get_all_versions_hash();
echo \"2. Hash: db=\$dbhash calc=\$calchash match=\" . (\$dbhash === \$calchash ? 'Y' : 'N') . \"\n\";

// Try calling the function with debug
echo \"3. Result: \" . (moodle_needs_upgrading() ? 'YES' : 'NO') . \"\n\";

// Check if there are extra checks
echo \"4. upgraderunning: \" . var_export(\$DB->get_field('config', 'value', array('name' => 'upgraderunning')), true) . \"\n\";

// Check for any_new_admin_settings
echo \"5. Check admin settings needed...\n\";
" 2>&1
echo "Exit: $?"
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 60 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 30
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 30 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

