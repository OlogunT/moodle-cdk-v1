<?php
/**
 * Send a test email via Moodle
 * Usage: php send-test-email.php <recipient-email>
 */

define('CLI_SCRIPT', true);

require_once('/app/moodle/config.php');
require_once($CFG->libdir.'/clilib.php');

// Get recipient from command line
$recipient = isset($argv[1]) ? $argv[1] : '';

if (empty($recipient)) {
    echo "ERROR: No recipient email provided\n";
    echo "Usage: php send-test-email.php <recipient-email>\n";
    exit(1);
}

// Validate email
if (!validate_email($recipient)) {
    echo "ERROR: Invalid email address: $recipient\n";
    exit(1);
}

echo "=== Sending Test Email via Moodle ===\n";
echo "Recipient: $recipient\n";
echo "From: noreply@tsin.ca\n";
echo "Timestamp: " . date('Y-m-d H:i:s') . " UTC\n";
echo "\n";

// Create a fake user object for email_to_user function
$user = new stdClass();
$user->email = $recipient;
$user->firstname = 'Test';
$user->lastname = 'Recipient';
$user->maildisplay = true;
$user->mailformat = 1; // HTML format
$user->id = -1;
$user->deleted = 0;
$user->suspended = 0;
$user->auth = 'manual';
$user->username = 'testuser';

// Create from user
$from = new stdClass();
$from->email = 'noreply@tsin.ca';
$from->firstname = 'Touchstone Institute';
$from->lastname = 'Moodle';
$from->maildisplay = true;
$from->mailformat = 1;
$from->id = -99;
$from->deleted = 0;
$from->suspended = 0;
$from->auth = 'manual';
$from->username = 'noreply';

$subject = 'Test Email from Moodle SES - ' . date('Y-m-d H:i:s');

$messagetext = "This is a test email from your Moodle installation.\n\n";
$messagetext .= "Sent via AWS SES at " . date('Y-m-d H:i:s') . " UTC\n\n";
$messagetext .= "SES Configuration:\n";
$messagetext .= "- SMTP Host: email-smtp.ca-central-1.amazonaws.com\n";
$messagetext .= "- SMTP Port: 587\n";
$messagetext .= "- Security: TLS (STARTTLS)\n";
$messagetext .= "- From: noreply@tsin.ca\n\n";
$messagetext .= "If you received this email, your Moodle SES integration is working correctly!\n\n";
$messagetext .= "Best regards,\n";
$messagetext .= "Touchstone Institute\n";

$messagehtml = "<html><body>";
$messagehtml .= "<h2>Test Email from Moodle SES</h2>";
$messagehtml .= "<p>This is a test email from your Moodle installation.</p>";
$messagehtml .= "<p><strong>Sent via AWS SES at " . date('Y-m-d H:i:s') . " UTC</strong></p>";
$messagehtml .= "<h3>SES Configuration:</h3>";
$messagehtml .= "<ul>";
$messagehtml .= "<li><strong>SMTP Host:</strong> email-smtp.ca-central-1.amazonaws.com</li>";
$messagehtml .= "<li><strong>SMTP Port:</strong> 587</li>";
$messagehtml .= "<li><strong>Security:</strong> TLS (STARTTLS)</li>";
$messagehtml .= "<li><strong>From:</strong> noreply@tsin.ca</li>";
$messagehtml .= "</ul>";
$messagehtml .= "<p>If you received this email, your Moodle SES integration is working correctly!</p>";
$messagehtml .= "<p>Best regards,<br>Touchstone Institute</p>";
$messagehtml .= "</body></html>";

echo "Sending email...\n";

// Send the email
$result = email_to_user($user, $from, $subject, $messagetext, $messagehtml);

if ($result) {
    echo "\n✓ SUCCESS: Email queued for delivery to $recipient\n";
    echo "\nThe email has been added to Moodle's email queue.\n";
    echo "It will be sent when the Moodle cron runs (usually within a few minutes).\n";
    echo "\nTo send immediately, run: php /app/moodle/admin/cli/cron.php\n";
    exit(0);
} else {
    echo "\n✗ FAILED: Could not queue email to $recipient\n";
    echo "Check Moodle logs for details.\n";
    exit(1);
}

