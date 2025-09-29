#!/bin/bash
# ============================================================================
# Configure Moodle to use AWS SES for email delivery
# ============================================================================
# This script configures Moodle to send emails via AWS SES SMTP
# It retrieves configuration from SSM Parameter Store and updates Moodle DB
# ============================================================================

set -euo pipefail

echo "=== MOODLE SES EMAIL CONFIGURATION START ===" "$(date -u)"

# ============================================================================
# STEP 1: Retrieve AWS Metadata and Configuration
# ============================================================================
echo "--- Step 1: Retrieving AWS metadata ---"

# Get IMDSv2 token
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

# Get region
REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || echo "ca-central-1")

echo "Region: $REGION"

# ============================================================================
# STEP 2: Retrieve SES Configuration from SSM
# ============================================================================
echo "--- Step 2: Retrieving SES configuration from SSM ---"

# Get SES SMTP endpoint
SES_SMTP_HOST=$(aws ssm get-parameter \
  --name "/moodle/ses/smtpEndpoint" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "email-smtp.$REGION.amazonaws.com")

# Get SES SMTP port
SES_SMTP_PORT=$(aws ssm get-parameter \
  --name "/moodle/ses/smtpPort" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "587")

# Get SES security protocol
SES_SECURITY=$(aws ssm get-parameter \
  --name "/moodle/ses/security" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "tls")

# Get FROM address
SES_FROM_ADDRESS=$(aws ssm get-parameter \
  --name "/moodle/ses/fromAddress" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "noreply@tsin.ca")

echo "SES SMTP Host: $SES_SMTP_HOST"
echo "SES SMTP Port: $SES_SMTP_PORT"
echo "SES Security: $SES_SECURITY"
echo "FROM Address: $SES_FROM_ADDRESS"

# ============================================================================
# STEP 3: Retrieve SES SMTP Credentials from Secrets Manager
# ============================================================================
echo "--- Step 3: Retrieving SES SMTP credentials ---"

# Try to get SES SMTP credentials from Secrets Manager
# If not found, user needs to create them manually
SES_SMTP_USER=""
SES_SMTP_PASS=""

if aws secretsmanager describe-secret \
  --secret-id "moodle/ses/smtp-credentials" \
  --region "$REGION" >/dev/null 2>&1; then
  
  echo "Found SES SMTP credentials in Secrets Manager"
  
  SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "moodle/ses/smtp-credentials" \
    --region "$REGION" \
    --query "SecretString" \
    --output text)
  
  SES_SMTP_USER=$(echo "$SECRET_JSON" | jq -r '.username // empty')
  SES_SMTP_PASS=$(echo "$SECRET_JSON" | jq -r '.password // empty')
  
  if [ -n "$SES_SMTP_USER" ] && [ -n "$SES_SMTP_PASS" ]; then
    echo "✓ SES SMTP credentials retrieved successfully"
  else
    echo "⚠ WARNING: SES SMTP credentials found but incomplete"
  fi
else
  echo "⚠ WARNING: SES SMTP credentials not found in Secrets Manager"
  echo "Please create secret 'moodle/ses/smtp-credentials' with username and password"
  echo "See: https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html"
fi

# ============================================================================
# STEP 4: Get Moodle Database Connection Details
# ============================================================================
echo "--- Step 4: Getting Moodle database connection ---"

CFG=/app/moodle/config.php

if [ ! -f "$CFG" ]; then
  echo "❌ ERROR: config.php not found at $CFG"
  exit 1
fi

# Extract database connection details from config.php
DB_HOST=$(grep -E '^\s*\$CFG->dbhost' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/")
DB_NAME=$(grep -E '^\s*\$CFG->dbname' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/")
DB_USER=$(grep -E '^\s*\$CFG->dbuser' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/")
DB_PASS=$(grep -E '^\s*\$CFG->dbpass' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/")

echo "Database Host: $DB_HOST"
echo "Database Name: $DB_NAME"

# ============================================================================
# STEP 5: Test SMTP Connectivity
# ============================================================================
echo "--- Step 5: Testing SMTP connectivity ---"

# Test DNS resolution
if getent hosts "$SES_SMTP_HOST" >/dev/null 2>&1; then
  echo "✓ DNS resolution successful for $SES_SMTP_HOST"
else
  echo "⚠ WARNING: DNS resolution failed for $SES_SMTP_HOST"
fi

# Test port connectivity
if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_SMTP_HOST/$SES_SMTP_PORT" 2>/dev/null; then
  echo "✓ SMTP port $SES_SMTP_PORT is reachable"
else
  echo "⚠ WARNING: SMTP port $SES_SMTP_PORT is NOT reachable"
  echo "This may indicate:"
  echo "  1. Security group egress rules blocking SMTP ports"
  echo "  2. Network ACL restrictions"
  echo "  3. No NAT Gateway and no SES VPC Endpoint"
fi

# ============================================================================
# STEP 6: Configure Moodle Email Settings in Database
# ============================================================================
echo "--- Step 6: Configuring Moodle email settings ---"

# Function to set Moodle config value
set_moodle_config() {
  local name=$1
  local value=$2
  
  mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
    "INSERT INTO mdl_config (name, value) VALUES ('$name', '$value') 
     ON DUPLICATE KEY UPDATE value='$value';" 2>/dev/null || true
}

# Configure SMTP settings
set_moodle_config "smtphosts" "$SES_SMTP_HOST:$SES_SMTP_PORT"
set_moodle_config "smtpsecure" "$SES_SECURITY"
set_moodle_config "smtpport" "$SES_SMTP_PORT"
set_moodle_config "noreplyaddress" "$SES_FROM_ADDRESS"
set_moodle_config "supportemail" "$SES_FROM_ADDRESS"

# Only set credentials if available
if [ -n "$SES_SMTP_USER" ] && [ -n "$SES_SMTP_PASS" ]; then
  set_moodle_config "smtpuser" "$SES_SMTP_USER"
  set_moodle_config "smtppass" "$SES_SMTP_PASS"
  echo "✓ SMTP credentials configured"
else
  echo "⚠ SMTP credentials not configured - manual setup required"
fi

# Additional email settings
set_moodle_config "smtpmaxbulk" "50"
set_moodle_config "mailnewline" "LF"

echo "✓ Moodle email settings configured in database"

# ============================================================================
# STEP 7: Verify Configuration
# ============================================================================
echo "--- Step 7: Verifying configuration ---"

mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
  "SELECT name, 
          CASE 
            WHEN name = 'smtppass' THEN '***REDACTED***'
            ELSE value 
          END as value 
   FROM mdl_config 
   WHERE name IN ('smtphosts', 'smtpuser', 'smtppass', 'smtpsecure', 'smtpport', 
                  'noreplyaddress', 'supportemail', 'smtpmaxbulk') 
   ORDER BY name;"

# ============================================================================
# STEP 8: Purge Moodle Caches
# ============================================================================
echo "--- Step 8: Purging Moodle caches ---"

if [ -f /app/moodle/admin/cli/purge_caches.php ]; then
  sudo -u apache php /app/moodle/admin/cli/purge_caches.php || true
  echo "✓ Moodle caches purged"
else
  echo "⚠ WARNING: Could not purge caches - file not found"
fi

# ============================================================================
# STEP 9: Test Email Sending (Optional)
# ============================================================================
echo "--- Step 9: Testing email functionality ---"

if [ -n "$SES_SMTP_USER" ] && [ -n "$SES_SMTP_PASS" ]; then
  echo "Attempting to send test email..."
  
  sudo -u apache php -r "
    define('CLI_SCRIPT', true);
    require_once('/app/moodle/config.php');
    require_once(\$CFG->libdir.'/moodlelib.php');
    
    \$testuser = \$DB->get_record('user', array('username' => 'tsin-admin'));
    if (!\$testuser) {
      \$testuser = \$DB->get_record('user', array('username' => 'moodle-admin'));
    }
    
    if (\$testuser) {
      \$subject = 'Moodle SES Test - ' . date('Y-m-d H:i:s');
      \$message = 'This is a test email sent via AWS SES SMTP.\n\n';
      \$message .= 'SMTP Host: $SES_SMTP_HOST\n';
      \$message .= 'SMTP Port: $SES_SMTP_PORT\n';
      \$message .= 'Security: $SES_SECURITY\n';
      
      \$result = email_to_user(\$testuser, \$testuser, \$subject, \$message);
      
      if (\$result) {
        echo \"✅ Test email queued successfully\n\";
        echo \"Recipient: {\$testuser->email}\n\";
      } else {
        echo \"❌ Failed to queue test email\n\";
      }
    } else {
      echo \"⚠ No test user found (tsin-admin or moodle-admin)\n\";
    }
  " || echo "⚠ Email test failed"
else
  echo "⚠ Skipping email test - SMTP credentials not configured"
fi

echo ""
echo "=== MOODLE SES EMAIL CONFIGURATION COMPLETE ===" "$(date -u)"
echo ""
echo "📧 Next Steps:"
echo "1. Verify email addresses in AWS SES Console (if in sandbox mode)"
echo "2. Request production access if sending to non-verified addresses"
echo "3. Monitor email queue: SELECT * FROM mdl_email_queue ORDER BY timecreated DESC LIMIT 10;"
echo "4. Check CloudWatch Logs for any email sending errors"
echo ""

