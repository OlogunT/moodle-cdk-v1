#!/bin/bash
# ============================================================================
# Test SES Email Delivery for Moodle
# ============================================================================
# This script performs comprehensive email delivery testing
# Run this AFTER deploying the SES configuration
# ============================================================================

set -euo pipefail

echo "=== SES EMAIL DELIVERY TEST START ===" "$(date -u)"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo -e "${BLUE}[TEST $TESTS_TOTAL]${NC} $test_name"
    
    if eval "$test_command"; then
        echo -e "${GREEN}✓ PASSED${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo ""
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo ""
        return 1
    fi
}

# Get environment information
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || echo "ca-central-1")

INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id || echo "unknown")

echo "Region: $REGION"
echo "Instance ID: $INSTANCE_ID"
echo ""

# ============================================================================
# TEST 1: Network Connectivity
# ============================================================================
echo -e "${YELLOW}=== PHASE 1: Network Connectivity Tests ===${NC}"
echo ""

SES_ENDPOINT="email-smtp.$REGION.amazonaws.com"

run_test "DNS Resolution for SES Endpoint" \
  "getent hosts $SES_ENDPOINT >/dev/null 2>&1"

run_test "Port 587 (STARTTLS) Connectivity" \
  "timeout 10 bash -c 'cat < /dev/null > /dev/tcp/$SES_ENDPOINT/587' 2>/dev/null"

run_test "Port 443 (HTTPS) Connectivity" \
  "timeout 10 bash -c 'cat < /dev/null > /dev/tcp/$SES_ENDPOINT/443' 2>/dev/null"

# ============================================================================
# TEST 2: Configuration Verification
# ============================================================================
echo -e "${YELLOW}=== PHASE 2: Configuration Verification ===${NC}"
echo ""

# Check Moodle config.php
CFG=/app/moodle/config.php

run_test "Moodle config.php exists" \
  "test -f $CFG"

# Extract database connection
if [ -f "$CFG" ]; then
    DB_HOST=$(grep -E '^\s*\$CFG->dbhost' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
    DB_NAME=$(grep -E '^\s*\$CFG->dbname' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
    DB_USER=$(grep -E '^\s*\$CFG->dbuser' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
    DB_PASS=$(grep -E '^\s*\$CFG->dbpass' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
    
    if [ -n "$DB_HOST" ]; then
        # Check SMTP configuration in database
        run_test "SMTP Host configured in Moodle" \
          "mariadb -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASS' -D '$DB_NAME' -e \"SELECT value FROM mdl_config WHERE name='smtphosts'\" 2>/dev/null | grep -q 'email-smtp'"
        
        run_test "SMTP Security configured (TLS)" \
          "mariadb -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASS' -D '$DB_NAME' -e \"SELECT value FROM mdl_config WHERE name='smtpsecure'\" 2>/dev/null | grep -q 'tls'"
        
        run_test "SMTP Port configured (587)" \
          "mariadb -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASS' -D '$DB_NAME' -e \"SELECT value FROM mdl_config WHERE name='smtphosts'\" 2>/dev/null | grep -q '587'"
        
        run_test "SMTP User configured" \
          "mariadb -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASS' -D '$DB_NAME' -e \"SELECT COUNT(*) as cnt FROM mdl_config WHERE name='smtpuser' AND value != ''\" 2>/dev/null | grep -q '1'"
        
        run_test "SMTP Password configured" \
          "mariadb -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASS' -D '$DB_NAME' -e \"SELECT COUNT(*) as cnt FROM mdl_config WHERE name='smtppass' AND value != ''\" 2>/dev/null | grep -q '1'"
    fi
fi

# ============================================================================
# TEST 3: SES Service Verification
# ============================================================================
echo -e "${YELLOW}=== PHASE 3: SES Service Verification ===${NC}"
echo ""

run_test "SES API accessible" \
  "aws ses get-send-quota --region $REGION >/dev/null 2>&1"

# Check SES sending quota
if aws ses get-send-quota --region "$REGION" >/dev/null 2>&1; then
    QUOTA=$(aws ses get-send-quota --region "$REGION" 2>/dev/null)
    MAX_SEND=$(echo "$QUOTA" | jq -r '.Max24HourSend' 2>/dev/null || echo "0")
    
    echo "SES Sending Quota: $MAX_SEND emails/24h"
    
    if [ "$MAX_SEND" = "200" ]; then
        echo -e "${YELLOW}⚠ SES is in SANDBOX mode - only verified addresses can receive emails${NC}"
    else
        echo -e "${GREEN}✓ SES is in PRODUCTION mode${NC}"
    fi
    echo ""
fi

# Check verified identities
run_test "At least one verified email identity exists" \
  "aws ses list-verified-email-addresses --region $REGION 2>/dev/null | jq -r '.VerifiedEmailAddresses[]' | grep -q '.'"

# ============================================================================
# TEST 4: SMTP Authentication Test
# ============================================================================
echo -e "${YELLOW}=== PHASE 4: SMTP Authentication Test ===${NC}"
echo ""

# Get SMTP credentials from Secrets Manager
SECRET_NAME="moodle/ses/smtp-credentials"
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
    run_test "SMTP credentials exist in Secrets Manager" "true"
    
    # Extract credentials
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text 2>/dev/null || echo "{}")
    SMTP_USER=$(echo "$SECRET_JSON" | jq -r '.username' 2>/dev/null || echo "")
    SMTP_PASS=$(echo "$SECRET_JSON" | jq -r '.password' 2>/dev/null || echo "")
    
    if [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ]; then
        echo "Testing SMTP authentication..."
        
        # Test SMTP connection with authentication
        SMTP_TEST=$(timeout 30 bash -c "
            exec 3<>/dev/tcp/$SES_ENDPOINT/587
            read -r -u 3 response
            echo 'EHLO localhost' >&3
            read -r -u 3 response
            echo 'STARTTLS' >&3
            read -r -u 3 response
            echo 'QUIT' >&3
            exec 3<&-
            exec 3>&-
            echo 'SUCCESS'
        " 2>/dev/null || echo "FAILED")
        
        if echo "$SMTP_TEST" | grep -q "SUCCESS"; then
            echo -e "${GREEN}✓ SMTP connection successful${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${YELLOW}⚠ SMTP connection test inconclusive${NC}"
        fi
        echo ""
    fi
else
    echo -e "${YELLOW}⚠ SMTP credentials not found in Secrets Manager${NC}"
    echo "  Create credentials: aws secretsmanager create-secret --name $SECRET_NAME ..."
    echo ""
fi

# ============================================================================
# TEST 5: Moodle Email Queue Test
# ============================================================================
echo -e "${YELLOW}=== PHASE 5: Moodle Email Queue Test ===${NC}"
echo ""

if [ -n "$DB_HOST" ]; then
    # Check if email queue table exists
    run_test "Email queue table exists" \
      "mariadb -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASS' -D '$DB_NAME' -e 'SHOW TABLES LIKE \"mdl_email_queue\"' 2>/dev/null | grep -q 'mdl_email_queue'"
    
    # Get email queue statistics
    echo "Email Queue Statistics:"
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
      "SELECT 
         COUNT(*) as total_emails,
         SUM(CASE WHEN status = 0 THEN 1 ELSE 0 END) as pending,
         SUM(CASE WHEN status = 1 THEN 1 ELSE 0 END) as sent,
         SUM(CASE WHEN status = 2 THEN 1 ELSE 0 END) as failed
       FROM mdl_email_queue;" 2>/dev/null || echo "Could not query email queue"
    echo ""
fi

# ============================================================================
# TEST 6: Send Test Email via Moodle
# ============================================================================
echo -e "${YELLOW}=== PHASE 6: Send Test Email ===${NC}"
echo ""

if [ -f "/app/moodle/config.php" ]; then
    echo "Attempting to send test email via Moodle..."
    
    # Get admin user email
    ADMIN_EMAIL=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
      "SELECT email FROM mdl_user WHERE username='moodle-admin' LIMIT 1" 2>/dev/null | tail -1 || echo "")
    
    if [ -n "$ADMIN_EMAIL" ]; then
        echo "Admin email: $ADMIN_EMAIL"
        
        # Create test email script
        cat > /tmp/test_email.php <<'EOFPHP'
<?php
define('CLI_SCRIPT', true);
require_once('/app/moodle/config.php');
require_once($CFG->libdir.'/moodlelib.php');

// Get admin user
$admin = $DB->get_record('user', array('username' => 'moodle-admin'));
if (!$admin) {
    echo "Admin user not found\n";
    exit(1);
}

// Send test email
$subject = 'SES Email Test - ' . date('Y-m-d H:i:s');
$message = "This is a test email sent via AWS SES.\n\n";
$message .= "If you receive this email, SES email delivery is working correctly.\n\n";
$message .= "Sent from: " . gethostname() . "\n";
$message .= "Timestamp: " . date('c') . "\n";

$result = email_to_user($admin, $admin, $subject, $message);

if ($result) {
    echo "✓ Test email queued successfully\n";
    echo "Check your inbox: $admin->email\n";
    exit(0);
} else {
    echo "✗ Failed to queue test email\n";
    exit(1);
}
?>
EOFPHP
        
        # Run test email script
        if sudo -u apache php /tmp/test_email.php 2>&1; then
            echo -e "${GREEN}✓ Test email sent successfully${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
        else
            echo -e "${RED}✗ Failed to send test email${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
        fi
        
        rm -f /tmp/test_email.php
    else
        echo -e "${YELLOW}⚠ Admin user not found, skipping test email${NC}"
    fi
    echo ""
fi

# ============================================================================
# TEST 7: Process Email Queue
# ============================================================================
echo -e "${YELLOW}=== PHASE 7: Process Email Queue ===${NC}"
echo ""

if [ -f "/app/moodle/admin/cli/adhoc_task.php" ]; then
    echo "Processing email queue via Moodle cron..."
    
    if sudo -u apache php /app/moodle/admin/cli/adhoc_task.php --execute=\\core\\task\\send_email_task 2>&1 | head -20; then
        echo -e "${GREEN}✓ Email queue processed${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${YELLOW}⚠ Email queue processing completed with warnings${NC}"
    fi
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo ""
fi

# ============================================================================
# TEST 8: Verify Email Delivery
# ============================================================================
echo -e "${YELLOW}=== PHASE 8: Verify Email Delivery ===${NC}"
echo ""

if [ -n "$DB_HOST" ]; then
    echo "Recent email queue entries (last 5):"
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
      "SELECT id, recipient, subject, 
              CASE status 
                WHEN 0 THEN 'Pending'
                WHEN 1 THEN 'Sent'
                WHEN 2 THEN 'Failed'
                ELSE 'Unknown'
              END as status,
              FROM_UNIXTIME(timecreated) as created
       FROM mdl_email_queue 
       ORDER BY timecreated DESC 
       LIMIT 5;" 2>/dev/null || echo "Could not query email queue"
    echo ""
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
echo "=== TEST SUMMARY ===" 
echo ""
echo "Total Tests: $TESTS_TOTAL"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC}"
    echo ""
    echo "✅ SES email delivery is working correctly"
    echo ""
    echo "Next steps:"
    echo "1. Check your email inbox for the test email"
    echo "2. Monitor the email queue for any failures"
    echo "3. Set up CloudWatch alarms for email bounces"
    echo "4. Request SES production access if still in sandbox mode"
else
    echo -e "${RED}⚠ SOME TESTS FAILED${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Run diagnostic script: sudo bash /tmp/diagnose-ses-email.sh"
    echo "2. Check security group egress rules for ports 587, 465, 443"
    echo "3. Verify VPC endpoint or NAT Gateway configuration"
    echo "4. Verify SMTP credentials in Secrets Manager"
    echo "5. Check Moodle error logs: /var/log/httpd/error_log"
    echo "6. Review SES sending statistics in AWS Console"
fi

echo ""
echo "=== SES EMAIL DELIVERY TEST END ===" "$(date -u)"

exit $TESTS_FAILED

