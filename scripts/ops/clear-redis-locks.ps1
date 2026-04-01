# Build PHP code and base64 encode it
$phpCode = @'
<?php
$r = new Redis();
$r->connect("moo-mo-isf4hcml1bjy.cgt4zg.0001.cac1.cache.amazonaws.com", 6379);
$r->select(0);
$lk = $r->keys("mdl_sess_lock:*");
echo "Found " . count($lk) . " lock keys\n";
foreach ($lk as $k) { echo "Del: $k\n"; $r->del($k); }
$al = $r->keys("*lock*");
echo "All lock keys: " . count($al) . "\n";
foreach ($al as $k) { echo "Del: $k\n"; $r->del($k); }
echo "Sessions: " . count($r->keys("mdl_sess_*")) . "\n";
echo "Done\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/clear_locks.php && php /tmp/clear_locks.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 60 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 15
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

