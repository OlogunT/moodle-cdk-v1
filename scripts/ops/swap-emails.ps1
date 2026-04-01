# Swap email addresses between c.stanclik and c.stanclik2
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

$u1 = $DB->get_record('user', array('username' => 'c.stanclik'));
$u2 = $DB->get_record('user', array('username' => 'c.stanclik2'));

if (!$u1 || !$u2) { echo "One or both users not found\n"; exit(1); }

echo "=== Before ===\n";
echo "c.stanclik  (id=$u1->id): $u1->email\n";
echo "c.stanclik2 (id=$u2->id): $u2->email\n";

// Use a temp email to avoid unique constraint violation
$DB->set_field('user', 'email', 'temp-swap@tsin.ca', array('id' => $u1->id));
$DB->set_field('user', 'email', $u1->email, array('id' => $u2->id));
$DB->set_field('user', 'email', $u2->email, array('id' => $u1->id));

$u1 = $DB->get_record('user', array('username' => 'c.stanclik'));
$u2 = $DB->get_record('user', array('username' => 'c.stanclik2'));

echo "\n=== After ===\n";
echo "c.stanclik  (id=$u1->id): $u1->email\n";
echo "c.stanclik2 (id=$u2->id): $u2->email\n";
echo "\nDone\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/swap_emails.php && php /tmp/swap_emails.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 30
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

