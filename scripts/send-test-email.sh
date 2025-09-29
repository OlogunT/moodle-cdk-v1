#!/bin/bash
# Send test email via Moodle
# Usage: ./send-test-email.sh <recipient-email>

set -e

RECIPIENT="${1:-}"

if [ -z "$RECIPIENT" ]; then
    echo "ERROR: No recipient email provided"
    echo "Usage: $0 <recipient-email>"
    exit 1
fi

echo "=== Sending Test Email via Moodle ==="
echo "Recipient: $RECIPIENT"
echo "From: noreply@tsin.ca"
echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
echo ""

# Download the PHP script
aws s3 cp s3://moodle-scripts-483382415631-ca-central-1/send-test-email.php /tmp/send-test-email.php

# Send the email
cd /app/moodle
sudo -u apache php /tmp/send-test-email.php "$RECIPIENT"

echo ""
echo "Processing email queue..."
echo ""

# Run cron to process the email queue
sudo -u apache php /app/moodle/admin/cli/cron.php --keep-alive=0

echo ""
echo "=== Email Sending Complete ==="
echo "Check the recipient's inbox (including spam folder)"

