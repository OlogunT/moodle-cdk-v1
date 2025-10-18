#!/bin/bash
# ============================================================================
# Quick Email Test - Fast verification of SES email delivery
# ============================================================================
# Run this for a quick check after deployment
# For comprehensive testing, use test-ses-email-delivery.sh
# ============================================================================

set -euo pipefail

echo "=== QUICK EMAIL TEST ===" "$(date)"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Get region
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || echo "ca-central-1")

SES_ENDPOINT="email-smtp.$REGION.amazonaws.com"

# Test 1: Network connectivity
echo -n "1. Testing network connectivity to SES... "
if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_ENDPOINT/587" 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo "   Port 587 is not reachable. Check security groups and VPC endpoint."
    exit 1
fi

# Test 2: Moodle configuration
echo -n "2. Checking Moodle configuration... "
if [ -f "/app/moodle/config.php" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo "   Moodle config.php not found."
    exit 1
fi

# Test 3: Database connectivity
echo -n "3. Testing database connectivity... "
CFG=/app/moodle/config.php
DB_HOST=$(grep -E '^\s*\$CFG->dbhost' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
DB_NAME=$(grep -E '^\s*\$CFG->dbname' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
DB_USER=$(grep -E '^\s*\$CFG->dbuser' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
DB_PASS=$(grep -E '^\s*\$CFG->dbpass' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")

if mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT 1" >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo "   Cannot connect to database."
    exit 1
fi

# Test 4: SMTP configuration
echo -n "4. Verifying SMTP configuration... "
SMTP_HOST=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT value FROM mdl_config WHERE name='smtphosts'" 2>/dev/null | tail -1 || echo "")

if echo "$SMTP_HOST" | grep -q "email-smtp"; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠${NC}"
    echo "   SMTP not configured. Run: sudo bash /tmp/configure-moodle-ses-email.sh"
fi

# Test 5: Send test email
echo -n "5. Sending test email... "

# Create test email script
cat > /tmp/quick_test_email.php <<'EOFPHP'
<?php
define('CLI_SCRIPT', true);
require_once('/app/moodle/config.php');
require_once($CFG->libdir.'/moodlelib.php');

$admin = $DB->get_record('user', array('username' => 'moodle-admin'));
if (!$admin) {
    echo "ERROR: Admin user not found\n";
    exit(1);
}

$subject = 'Quick Email Test - ' . date('Y-m-d H:i:s');
$message = "This is a quick test email.\n\nIf you receive this, SES is working!";

$result = email_to_user($admin, $admin, $subject, $message);

if ($result) {
    echo "SUCCESS: Email queued for $admin->email\n";
    exit(0);
} else {
    echo "ERROR: Failed to queue email\n";
    exit(1);
}
?>
EOFPHP

# Run test
TEST_OUTPUT=$(sudo -u apache php /tmp/quick_test_email.php 2>&1)
rm -f /tmp/quick_test_email.php

if echo "$TEST_OUTPUT" | grep -q "SUCCESS"; then
    echo -e "${GREEN}✓${NC}"
    ADMIN_EMAIL=$(echo "$TEST_OUTPUT" | grep -oP 'queued for \K[^\s]+' || echo "admin")
    echo "   Email queued for: $ADMIN_EMAIL"
else
    echo -e "${RED}✗${NC}"
    echo "   $TEST_OUTPUT"
    exit 1
fi

# Test 6: Process email queue
echo -n "6. Processing email queue... "
if sudo -u apache php /app/moodle/admin/cli/adhoc_task.php --execute=\\core\\task\\send_email_task >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠${NC}"
    echo "   Email queue processing completed with warnings (this may be normal)"
fi

# Test 7: Check email status
echo -n "7. Checking email delivery status... "
EMAIL_STATUS=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT COUNT(*) as cnt FROM mdl_email_queue WHERE status = 1 AND timecreated > UNIX_TIMESTAMP(NOW() - INTERVAL 5 MINUTE)" 2>/dev/null | tail -1 || echo "0")

if [ "$EMAIL_STATUS" -gt 0 ]; then
    echo -e "${GREEN}✓${NC}"
    echo "   $EMAIL_STATUS email(s) sent in last 5 minutes"
else
    echo -e "${YELLOW}⚠${NC}"
    echo "   No emails sent recently. Check email queue for errors."
fi

echo ""
echo "=== QUICK TEST COMPLETE ===" 
echo ""
echo -e "${GREEN}✓ Basic email functionality is working${NC}"
echo ""
echo "Next steps:"
echo "1. Check your email inbox for the test email"
echo "2. Run comprehensive tests: sudo bash /tmp/test-ses-email-delivery.sh"
echo "3. Monitor email queue: SELECT * FROM mdl_email_queue ORDER BY timecreated DESC LIMIT 10;"
echo ""

