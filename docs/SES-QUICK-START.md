# SES Email Quick Start Guide

## 🚀 5-Minute Setup

### Prerequisites
- AWS CLI configured
- CDK CLI installed (`npm install -g aws-cdk`)
- SES verified email addresses or domain

---

## Step 1: Synthesize Stack (No Deployment)

```bash
# Navigate to project root
cd c:\github\moodle-cdk0

# Install dependencies
npm install

# Synthesize stack to verify changes
cdk synth MoodleCdkStack
```

**Expected Output:**
- CloudFormation template generated in `cdk.out/`
- No errors or warnings
- SES-related resources visible in template

---

## Step 2: Verify SES Resources

```bash
# Check for SES resources in template
cat cdk.out/MoodleCdkStack.template.json | jq '.Resources | keys | .[] | select(. | contains("Ses"))'
```

**Expected Resources:**
- `SesVpcEndpointSecurityGroup`
- `SesSmtpVpcEndpoint`
- IAM policies with SES permissions
- SSM parameters for SES configuration

---

## Step 3: Deploy Stack (When Ready)

```bash
# Deploy with VPC endpoint (recommended)
cdk deploy MoodleCdkStack --parameters CreateSesVpcEndpoint=true

# Or deploy without VPC endpoint (uses NAT Gateway)
cdk deploy MoodleCdkStack --parameters CreateSesVpcEndpoint=false
```

---

## Step 4: Verify Email Addresses in SES

```bash
# Verify individual email address
aws ses verify-email-identity \
  --email-address noreply@tsin.ca \
  --region ca-central-1

# Check verification status
aws ses list-verified-email-addresses --region ca-central-1
```

**Important:** Check your email inbox for verification link!

---

## Step 5: Create SMTP Credentials

### Option A: AWS Console (Easiest)
1. Go to: https://console.aws.amazon.com/ses/home#/smtp
2. Click "Create SMTP Credentials"
3. Download credentials (save securely!)

### Option B: AWS CLI
```bash
# Create IAM user
aws iam create-user --user-name moodle-ses-smtp

# Attach SES policy
aws iam attach-user-policy \
  --user-name moodle-ses-smtp \
  --policy-arn arn:aws:iam::aws:policy/AmazonSesSendingAccess

# Create access key
aws iam create-access-key --user-name moodle-ses-smtp
```

**Note:** Convert access key to SMTP password using [AWS documentation](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html)

---

## Step 6: Store Credentials in Secrets Manager

```bash
# Create secret with SMTP credentials
aws secretsmanager create-secret \
  --name moodle/ses/smtp-credentials \
  --description "SES SMTP credentials for Moodle" \
  --secret-string '{
    "username": "YOUR_SMTP_USERNAME",
    "password": "YOUR_SMTP_PASSWORD"
  }' \
  --region ca-central-1
```

---

## Step 7: Configure Moodle

### Option A: Automated Script
```bash
# Connect to instance via SSM
aws ssm start-session --target i-INSTANCE_ID

# Run configuration script
sudo bash /tmp/configure-moodle-ses-email.sh
```

### Option B: Manual Configuration
```bash
# Connect to Moodle database
mariadb -h DB_ENDPOINT -u moodleuser -p

# Set SMTP configuration
INSERT INTO mdl_config (name, value) VALUES 
  ('smtphosts', 'email-smtp.ca-central-1.amazonaws.com:587')
  ON DUPLICATE KEY UPDATE value='email-smtp.ca-central-1.amazonaws.com:587';

INSERT INTO mdl_config (name, value) VALUES 
  ('smtpsecure', 'tls')
  ON DUPLICATE KEY UPDATE value='tls';

INSERT INTO mdl_config (name, value) VALUES 
  ('smtpuser', 'YOUR_SMTP_USERNAME')
  ON DUPLICATE KEY UPDATE value='YOUR_SMTP_USERNAME';

INSERT INTO mdl_config (name, value) VALUES 
  ('smtppass', 'YOUR_SMTP_PASSWORD')
  ON DUPLICATE KEY UPDATE value='YOUR_SMTP_PASSWORD';
```

---

## Step 8: Test Email Sending

```bash
# Send test email via Moodle CLI
cd /app/moodle
sudo -u apache php -r "
  define('CLI_SCRIPT', true);
  require_once('/app/moodle/config.php');
  require_once(\$CFG->libdir.'/moodlelib.php');
  
  \$testuser = \$DB->get_record('user', array('username' => 'moodle-admin'));
  \$result = email_to_user(\$testuser, \$testuser, 'Test Email', 'This is a test');
  
  echo \$result ? 'Email sent successfully' : 'Email failed';
"
```

---

## 🔍 Troubleshooting

### Issue: "Port 587 not reachable"

**Solution:**
```bash
# Run diagnostic script
sudo bash /tmp/diagnose-ses-email.sh

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids sg-XXXXXXXX \
  --query "SecurityGroups[0].IpPermissionsEgress[?ToPort==\`587\`]"

# Verify VPC endpoint exists
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ca-central-1.email-smtp"
```

### Issue: "Authentication failed"

**Solution:**
```bash
# Verify credentials in Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id moodle/ses/smtp-credentials \
  --query SecretString \
  --output text | jq .

# Test SMTP authentication manually
openssl s_client -connect email-smtp.ca-central-1.amazonaws.com:587 -starttls smtp
```

### Issue: "Email not verified"

**Solution:**
```bash
# Check SES sandbox status
aws ses get-send-quota --region ca-central-1

# Verify email address
aws ses verify-email-identity \
  --email-address noreply@tsin.ca \
  --region ca-central-1

# Request production access
# Go to: https://console.aws.amazon.com/ses/home#/account
```

---

## 📊 Monitoring

### Check Email Queue
```sql
SELECT 
  COUNT(*) as total,
  SUM(CASE WHEN status = 0 THEN 1 ELSE 0 END) as pending,
  SUM(CASE WHEN status = 1 THEN 1 ELSE 0 END) as sent,
  SUM(CASE WHEN status = 2 THEN 1 ELSE 0 END) as failed
FROM mdl_email_queue;
```

### View Recent Emails
```sql
SELECT id, recipient, subject, status, FROM_UNIXTIME(timecreated) as created
FROM mdl_email_queue 
ORDER BY timecreated DESC 
LIMIT 10;
```

### CloudWatch Metrics
```bash
# View SES sending metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/SES \
  --metric-name Send \
  --dimensions Name=Region,Value=ca-central-1 \
  --start-time 2025-01-01T00:00:00Z \
  --end-time 2025-01-31T23:59:59Z \
  --period 3600 \
  --statistics Sum
```

---

## 💰 Cost Estimate

### With VPC Endpoint (Recommended)
- VPC Endpoint: ~$7.30/month
- Data Transfer: $0.01/GB
- SES Emails: $0.10/1000 emails
- **Total:** ~$7.30/month + usage

### Without VPC Endpoint
- NAT Gateway: ~$32.85/month per AZ
- Data Transfer: $0.045/GB
- SES Emails: $0.10/1000 emails
- **Total:** ~$65.70/month (2 AZs) + usage

**Savings:** ~$58/month with VPC endpoint

---

## ✅ Verification Checklist

- [ ] CDK stack synthesized successfully
- [ ] SES resources visible in CloudFormation template
- [ ] Email addresses verified in SES
- [ ] SMTP credentials created
- [ ] Credentials stored in Secrets Manager
- [ ] Stack deployed (when ready)
- [ ] VPC endpoint created (or NAT Gateway verified)
- [ ] Security group rules applied
- [ ] Moodle configuration completed
- [ ] Test email sent successfully
- [ ] Email queue monitored

---

## 📚 Additional Resources

- **Full Documentation:** [docs/SES-EMAIL-CONFIGURATION.md](./SES-EMAIL-CONFIGURATION.md)
- **Diagnostic Script:** `scripts/diagnose-ses-email.sh`
- **Configuration Script:** `scripts/configure-moodle-ses-email.sh`
- **Deployment Script:** `scripts/deploy-ses-email-config.ps1`

---

## 🆘 Support

If you encounter issues:

1. Run diagnostic script: `sudo bash /tmp/diagnose-ses-email.sh`
2. Check CloudWatch Logs: `/aws/ec2/moodle`
3. Review SES sending statistics in AWS Console
4. Verify all checklist items above

---

**Last Updated:** 2025-01-29  
**Region:** ca-central-1  
**Moodle Version:** 5.0

