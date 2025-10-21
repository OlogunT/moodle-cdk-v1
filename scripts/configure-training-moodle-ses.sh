#!/bin/bash
set -e

REGION=ca-central-1

echo "=== Step 1: Retrieving SES Configuration from SSM ==="
SES_SMTP_HOST=$(aws ssm get-parameter --name /moodle/ses/smtpEndpoint --region $REGION --query Parameter.Value --output text)
SES_SMTP_PORT=$(aws ssm get-parameter --name /moodle/ses/smtpPort --region $REGION --query Parameter.Value --output text)
SES_SECURITY=$(aws ssm get-parameter --name /moodle/ses/security --region $REGION --query Parameter.Value --output text)
SES_FROM_ADDRESS=$(aws ssm get-parameter --name /moodle/ses/fromAddress --region $REGION --query Parameter.Value --output text)

echo "SMTP Host: $SES_SMTP_HOST"
echo "SMTP Port: $SES_SMTP_PORT"
echo "Security: $SES_SECURITY"
echo "From Address: $SES_FROM_ADDRESS"

echo ""
echo "=== Step 2: Retrieving SES SMTP Credentials from Secrets Manager ==="
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id moodle/ses/smtp-credentials --region $REGION --query SecretString --output text)
SES_SMTP_USER=$(echo "$SECRET_JSON" | jq -r .username)
SES_SMTP_PASS=$(echo "$SECRET_JSON" | jq -r .password)

if [ -n "$SES_SMTP_USER" ] && [ -n "$SES_SMTP_PASS" ]; then
  echo "✓ SES SMTP credentials retrieved successfully"
  echo "Username: $SES_SMTP_USER"
else
  echo "✗ Failed to retrieve SES SMTP credentials"
  exit 1
fi

echo ""
echo "=== Step 3: Retrieving Training Moodle Database Credentials ==="
DB_SECRET_ARN=$(aws secretsmanager list-secrets --region $REGION --query "SecretList[?contains(Name,\`TrainingMoodleDbSecret\`)].ARN" --output text)
DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region $REGION --query SecretString --output text)
DB_HOST=$(echo "$DB_CREDS" | jq -r .host)
DB_USER=$(echo "$DB_CREDS" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS" | jq -r .password)

echo "Database Host: $DB_HOST"

echo ""
echo "=== Step 4: Configuring Moodle SMTP Settings in Database ==="

# Configure SMTP settings
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('smtphosts', '$SES_SMTP_HOST:$SES_SMTP_PORT') ON DUPLICATE KEY UPDATE value='$SES_SMTP_HOST:$SES_SMTP_PORT';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('smtpsecure', '$SES_SECURITY') ON DUPLICATE KEY UPDATE value='$SES_SECURITY';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('smtpport', '$SES_SMTP_PORT') ON DUPLICATE KEY UPDATE value='$SES_SMTP_PORT';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('noreplyaddress', '$SES_FROM_ADDRESS') ON DUPLICATE KEY UPDATE value='$SES_FROM_ADDRESS';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('supportemail', '$SES_FROM_ADDRESS') ON DUPLICATE KEY UPDATE value='$SES_FROM_ADDRESS';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('smtpuser', '$SES_SMTP_USER') ON DUPLICATE KEY UPDATE value='$SES_SMTP_USER';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('smtppass', '$SES_SMTP_PASS') ON DUPLICATE KEY UPDATE value='$SES_SMTP_PASS';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('smtpmaxbulk', '50') ON DUPLICATE KEY UPDATE value='50';" 2>&1 | grep -v Warning

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "INSERT INTO mdl_config (name, value) VALUES ('mailnewline', 'LF') ON DUPLICATE KEY UPDATE value='LF';" 2>&1 | grep -v Warning

echo "✓ SMTP settings configured in database"

echo ""
echo "=== Step 5: Verifying Configuration ==="
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "SELECT name, CASE WHEN name='smtppass' THEN '***REDACTED***' ELSE value END as value FROM mdl_config WHERE name IN ('smtphosts', 'smtpuser', 'smtppass', 'smtpsecure', 'smtpport', 'noreplyaddress', 'supportemail', 'smtpmaxbulk', 'mailnewline') ORDER BY name;" 2>&1 | grep -v Warning

echo ""
echo "=== Step 6: Purging Moodle Caches ==="
cd /app/moodle
sudo -u apache php admin/cli/purge_caches.php 2>&1 | head -20

echo ""
echo "=== Step 7: Testing SMTP Connectivity ==="
if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_SMTP_HOST/$SES_SMTP_PORT" 2>/dev/null; then
  echo "✓ SMTP port $SES_SMTP_PORT is reachable on $SES_SMTP_HOST"
else
  echo "⚠ WARNING: SMTP port $SES_SMTP_PORT is NOT reachable"
fi

echo ""
echo "========================================"
echo "✅ Training Moodle SMTP Configuration Complete!"
echo "========================================"
echo ""
echo "Configuration Summary:"
echo "- SMTP Host: $SES_SMTP_HOST:$SES_SMTP_PORT"
echo "- Security: $SES_SECURITY"
echo "- From Address: $SES_FROM_ADDRESS"
echo "- SMTP User: $SES_SMTP_USER"
echo "- Max Bulk: 50"
echo "- Mail Newline: LF"
echo ""
echo "Next Steps:"
echo "1. Test email sending from Moodle admin interface"
echo "2. Check Site Administration > Server > Email > Outgoing mail configuration"
echo "3. Send a test email to verify SES integration"

