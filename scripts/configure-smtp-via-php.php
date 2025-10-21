<?php
/**
 * Configure Training Moodle SMTP settings using SES
 * This script retrieves SES configuration from AWS and updates Moodle config
 */

define('CLI_SCRIPT', true);

require('/app/moodle/config.php');
require_once($CFG->libdir.'/clilib.php');

// Get SES configuration from SSM Parameter Store
$region = 'ca-central-1';

echo "=== Retrieving SES Configuration from SSM ===\n";
$smtp_host = trim(shell_exec("aws ssm get-parameter --name /moodle/ses/smtpEndpoint --region $region --query Parameter.Value --output text"));
$smtp_port = trim(shell_exec("aws ssm get-parameter --name /moodle/ses/smtpPort --region $region --query Parameter.Value --output text"));
$smtp_security = trim(shell_exec("aws ssm get-parameter --name /moodle/ses/security --region $region --query Parameter.Value --output text"));
$from_address = trim(shell_exec("aws ssm get-parameter --name /moodle/ses/fromAddress --region $region --query Parameter.Value --output text"));

echo "SMTP Host: $smtp_host\n";
echo "SMTP Port: $smtp_port\n";
echo "Security: $smtp_security\n";
echo "From Address: $from_address\n\n";

echo "=== Retrieving SES SMTP Credentials from Secrets Manager ===\n";
$secret_json = trim(shell_exec("aws secretsmanager get-secret-value --secret-id moodle/ses/smtp-credentials --region $region --query SecretString --output text"));
$secret_data = json_decode($secret_json, true);

if (!$secret_data || !isset($secret_data['username']) || !isset($secret_data['password'])) {
    echo "ERROR: Failed to retrieve SES SMTP credentials\n";
    exit(1);
}

$smtp_user = $secret_data['username'];
$smtp_pass = $secret_data['password'];

echo "✓ SES SMTP credentials retrieved successfully\n";
echo "Username: $smtp_user\n\n";

echo "=== Configuring Moodle SMTP Settings ===\n";

// Set SMTP configuration
set_config('smtphosts', "$smtp_host:$smtp_port");
set_config('smtpsecure', $smtp_security);
set_config('smtpuser', $smtp_user);
set_config('smtppass', $smtp_pass);
set_config('noreplyaddress', $from_address);
set_config('supportemail', $from_address);
set_config('smtpmaxbulk', '50');
set_config('mailnewline', 'LF');

echo "✓ SMTP settings configured in database\n\n";

echo "=== Verifying Configuration ===\n";
echo "SMTP Hosts: " . get_config('core', 'smtphosts') . "\n";
echo "SMTP Security: " . get_config('core', 'smtpsecure') . "\n";
echo "SMTP User: " . get_config('core', 'smtpuser') . "\n";
echo "SMTP Pass: ***REDACTED***\n";
echo "No-Reply Address: " . get_config('core', 'noreplyaddress') . "\n";
echo "Support Email: " . get_config('core', 'supportemail') . "\n";
echo "SMTP Max Bulk: " . get_config('core', 'smtpmaxbulk') . "\n";
echo "Mail Newline: " . get_config('core', 'mailnewline') . "\n\n";

echo "=== Purging Moodle Caches ===\n";
purge_all_caches();
echo "✓ Caches purged\n\n";

echo "========================================\n";
echo "✓ Training Moodle SMTP Configuration Complete!\n";
echo "========================================\n\n";

echo "Configuration Summary:\n";
echo "- SMTP Host: $smtp_host:$smtp_port\n";
echo "- Security: $smtp_security\n";
echo "- From Address: $from_address\n";
echo "- SMTP User: $smtp_user\n";
echo "- Max Bulk: 50\n";
echo "- Mail Newline: LF\n\n";

echo "Next Steps:\n";
echo "1. Test email sending from Moodle admin interface\n";
echo "2. Check Site Administration > Server > Email > Outgoing mail configuration\n";
echo "3. Send a test email to verify SES integration\n";

exit(0);

