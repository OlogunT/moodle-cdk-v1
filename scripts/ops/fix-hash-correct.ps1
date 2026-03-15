$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'fix-hash-c.json'

$bash = @'
timeout 30 php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

// Get the correct hash from Moodle's own method
\$hash = core_component::get_all_versions_hash();
echo \"Correct hash: \$hash\n\";

// Update DB
\$DB->set_field('config', 'value', \$hash, array('name' => 'allversionshash'));
echo \"Updated DB\n\";

// Verify
\$dbhash = \$DB->get_field('config', 'value', array('name' => 'allversionshash'));
echo \"DB hash now: \$dbhash\n\";
echo \"Match: \" . (\$dbhash === \$hash ? 'YES' : 'NO') . \"\n\";

// Final check
require_once(\$CFG->libdir . '/upgradelib.php');
echo \"moodle_needs_upgrading: \" . (moodle_needs_upgrading() ? 'YES' : 'NO') . \"\n\";
" 2>&1
echo "Exit: $?"

echo "=== Speed test ==="
curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s\n" -m 15 http://localhost/login/index.php 2>&1
curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s\n" -m 15 http://localhost/ 2>&1
echo "=== DONE ==="
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 60 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 35
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

