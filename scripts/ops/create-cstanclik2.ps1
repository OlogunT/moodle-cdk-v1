# Create c.stanclik2 account with same permissions as tsin-admin
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once($CFG->libdir . '/moodlelib.php');

echo "=== 1. Get tsin-admin info ===\n";
$admin = $DB->get_record('user', array('username' => 'tsin-admin'));
if (!$admin) { echo "tsin-admin not found\n"; exit(1); }
echo "tsin-admin ID: $admin->id\n";
echo "Is site admin: " . (is_siteadmin($admin->id) ? "YES" : "NO") . "\n";

// Get tsin-admin roles
$sysctx = context_system::instance();
$adminroles = get_user_roles($sysctx, $admin->id);
echo "System roles:\n";
foreach ($adminroles as $r) { echo "  $r->shortname (id=$r->roleid)\n"; }

echo "\n=== 2. Check if c.stanclik2 already exists ===\n";
$existing = $DB->get_record('user', array('username' => 'c.stanclik2'));
if ($existing) {
    echo "User already exists (id=$existing->id) - skipping creation\n";
    $newuser = $existing;
} else {
    echo "Creating new user...\n";
    $newuser = new stdClass();
    $newuser->username = 'c.stanclik2';
    $newuser->auth = 'manual';
    $newuser->confirmed = 1;
    $newuser->mnethostid = $CFG->mnet_localhost_id;
    $newuser->firstname = 'Connie';
    $newuser->lastname = 'Stanclik';
    $newuser->email = 'c.stanclik2@tsin.ca';
    $newuser->city = '';
    $newuser->country = 'CA';
    $newuser->lang = 'en';
    $newuser->timezone = 'America/Toronto';
    $newuser->password = hash_internal_user_password('Tsin@2025!@#');
    $newuser->timecreated = time();
    $newuser->timemodified = time();

    $newuser->id = $DB->insert_record('user', $newuser);
    echo "Created user ID: $newuser->id\n";
}

echo "\n=== 3. Assign same system roles as tsin-admin ===\n";
foreach ($adminroles as $r) {
    $existing_assignment = $DB->get_record('role_assignments', array(
        'roleid' => $r->roleid,
        'contextid' => $sysctx->id,
        'userid' => $newuser->id
    ));
    if (!$existing_assignment) {
        role_assign($r->roleid, $newuser->id, $sysctx->id);
        echo "Assigned role: $r->shortname\n";
    } else {
        echo "Role already assigned: $r->shortname\n";
    }
}

echo "\n=== 4. Add as site admin if tsin-admin is one ===\n";
if (is_siteadmin($admin->id)) {
    $admins = explode(',', $CFG->siteadmins);
    if (!in_array($newuser->id, $admins)) {
        $admins[] = $newuser->id;
        set_config('siteadmins', implode(',', $admins));
        echo "Added as site admin\n";
    } else {
        echo "Already a site admin\n";
    }
}

echo "\n=== 5. Verify ===\n";
$verify = $DB->get_record('user', array('username' => 'c.stanclik2'));
echo "Username: $verify->username\n";
echo "Name: $verify->firstname $verify->lastname\n";
echo "Email: $verify->email\n";
echo "ID: $verify->id\n";
echo "Is site admin: " . (is_siteadmin($verify->id) ? "YES" : "NO") . "\n";
$roles = get_user_roles($sysctx, $verify->id);
echo "System roles:\n";
foreach ($roles as $r) { echo "  $r->shortname\n"; }

echo "\nDone - c.stanclik2 can log in with password: Tsin@2025!@#\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/create_user.php && php /tmp/create_user.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 180 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 60
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

