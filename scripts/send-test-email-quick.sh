#!/bin/bash
# Send test email quickly via Moodle (without full cron)
# Usage: ./send-test-email-quick.sh <recipient-email>

set -e

RECIPIENT="${1:-dayologun@gmail.com}"

echo "=== Quick Test Email via Moodle ==="
echo "Recipient: $RECIPIENT"
echo "From: noreply@tsin.ca"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
echo ""

# Create a simple PHP script to send email using Moodle's email_to_user function
cat > /tmp/quick-email.php <<'EOFPHP'
<?php
define('CLI_SCRIPT', true);
require_once('/app/moodle/config.php');
require_once($CFG->libdir.'/moodlelib.php');

$recipient = $argv[1];
echo "Sending email to: $recipient\n";

// Create a fake user object for the recipient
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
$from = core_user::get_noreply_user();

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

// Send the email using Moodle's email_to_user function
$result = email_to_user($user, $from, $subject, $messagetext, $messagehtml);

if ($result) {
    echo "✓ SUCCESS: Email queued for delivery to $recipient\n";
    exit(0);
} else {
    echo "✗ FAILED: Could not queue email\n";
    exit(1);
}
EOFPHP

# Process the email queue
echo ""
echo "Processing email queue..."
sudo -u apache php /app/moodle/admin/cli/adhoc_task.php --execute --classname='\core\task\email_task'

# Send the email
cd /app/moodle
sudo -u apache php /tmp/quick-email.php "$RECIPIENT"

echo ""
echo "=== Email Sent ==="
echo "Check the recipient's inbox (including spam folder)"
echo "Email should arrive within 1-2 minutes"

