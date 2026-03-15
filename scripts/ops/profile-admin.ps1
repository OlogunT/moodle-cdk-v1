$shellCmd = @'
# Write profile script as base64 to avoid escaping issues
echo '<?php
define("CLI_SCRIPT", true);
$t0 = microtime(true);
require("/app/moodle/config.php");
$t1 = microtime(true);
echo "config.php: " . round($t1-$t0, 2) . "s\n";

require_once($CFG->libdir."/adminlib.php");
$t2 = microtime(true);
echo "adminlib.php: " . round($t2-$t1, 2) . "s\n";

$result = moodle_needs_upgrading();
$t3 = microtime(true);
echo "moodle_needs_upgrading: " . ($result ? "YES" : "NO") . " in " . round($t3-$t2, 2) . "s\n";

$admin = admin_get_root(false, false);
$t4 = microtime(true);
echo "admin_get_root(lite): " . round($t4-$t3, 2) . "s\n";

$admin = admin_get_root(false, true);
$t5 = microtime(true);
echo "admin_get_root(full): " . round($t5-$t4, 2) . "s\n";

echo "Total: " . round($t5-$t0, 2) . "s\n";
' > /tmp/profile_admin.php

timeout 300 php /tmp/profile_admin.php 2>&1
echo "EXIT=$?"
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 600 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"

