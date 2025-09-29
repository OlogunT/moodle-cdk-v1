# AWS SES Email Configuration for Moodle CDK

## 📧 Overview

This document provides comprehensive guidance for enabling AWS Simple Email Service (SES) with your Moodle deployment. The CDK stack has been enhanced with multiple layers of email infrastructure to ensure reliable email delivery.

---

## 🏗️ Architecture Changes Implemented

### 1. **Security Group Enhancements**

#### Explicit SMTP Egress Rules
The Moodle security group now includes explicit egress rules for SMTP traffic:

- **Port 587 (STARTTLS)** - ✅ **RECOMMENDED** - Primary port for SES SMTP
- **Port 465 (TLS Wrapper)** - ✅ Alternative port for legacy systems
- **Port 25** - ❌ **AVOIDED** - EC2 throttles this port by default

```typescript
// Explicit egress rules added to MoodleSecurityGroup
moodleSecurityGroup.addEgressRule(
  ec2.Peer.anyIpv4(),
  ec2.Port.tcp(587),
  'Allow SMTP STARTTLS to SES (port 587 - recommended)'
);
```

### 2. **VPC Endpoint for SES SMTP** (Optional but Recommended)

A VPC Interface Endpoint has been added for SES SMTP service:

**Benefits:**
- ✅ Eliminates need for NAT Gateway for email traffic (cost savings)
- ✅ Improved reliability and lower latency
- ✅ Private DNS automatically resolves `email-smtp.{region}.amazonaws.com`
- ✅ Traffic stays within AWS network

**Configuration:**
- Service: `com.amazonaws.{region}.email-smtp`
- Subnets: Private subnets with egress
- Private DNS: Enabled
- Ports: 587 (STARTTLS), 465 (TLS)

**Control Parameter:**
```bash
# Enable VPC Endpoint (default: true)
cdk deploy --parameters CreateSesVpcEndpoint=true

# Disable VPC Endpoint (use NAT Gateway instead)
cdk deploy --parameters CreateSesVpcEndpoint=false
```

### 3. **IAM Permissions**

EC2 instances now have comprehensive SES permissions:

```typescript
// SES API permissions
- ses:SendEmail
- ses:SendRawEmail
- ses:SendTemplatedEmail
- ses:SendBulkTemplatedEmail

// Secrets Manager access for SMTP credentials
- secretsmanager:GetSecretValue (for moodle/ses/*)
```

**Conditional Access:**
- FROM addresses restricted to: `noreply@tsin.ca`, `noreply@learning.tsin.ca`, `it@tsin.ca`

### 4. **SSM Parameter Store Configuration**

The following parameters are automatically created:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `/moodle/ses/smtpEndpoint` | `email-smtp.{region}.amazonaws.com` | SES SMTP endpoint |
| `/moodle/ses/smtpPort` | `587` | SMTP port (STARTTLS) |
| `/moodle/ses/security` | `tls` | Security protocol |
| `/moodle/ses/fromAddress` | `noreply@tsin.ca` | Default FROM address |

---

## 🚀 Deployment Instructions

### Step 1: Synthesize the Stack (No Deployment)

```bash
# Synthesize to verify changes
cdk synth MoodleCdkStack

# Review the generated CloudFormation template
cat cdk.out/MoodleCdkStack.template.json | jq '.Resources | keys | .[] | select(. | contains("Ses"))'
```

### Step 2: Deploy with SES VPC Endpoint (Recommended)

```bash
# Deploy with VPC endpoint enabled (default)
cdk deploy MoodleCdkStack --parameters CreateSesVpcEndpoint=true

# Or deploy without VPC endpoint (uses NAT Gateway)
cdk deploy MoodleCdkStack --parameters CreateSesVpcEndpoint=false
```

### Step 3: Verify SES Identity

Before sending emails, verify your domain or email addresses in SES:

```bash
# Verify a domain (recommended for production)
aws ses verify-domain-identity --domain tsin.ca --region ca-central-1

# Or verify individual email addresses (for testing)
aws ses verify-email-identity --email-address noreply@tsin.ca --region ca-central-1
aws ses verify-email-identity --email-address it@tsin.ca --region ca-central-1
```

### Step 4: Create SES SMTP Credentials

Generate SMTP credentials for SES:

```bash
# 1. Create IAM user for SMTP (via AWS Console or CLI)
aws iam create-user --user-name moodle-ses-smtp

# 2. Attach SES sending policy
aws iam attach-user-policy \
  --user-name moodle-ses-smtp \
  --policy-arn arn:aws:iam::aws:policy/AmazonSesSendingAccess

# 3. Create access key (save the output!)
aws iam create-access-key --user-name moodle-ses-smtp

# 4. Convert access key to SMTP credentials
# Use this tool: https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html
# Or use the AWS Console: SES > SMTP Settings > Create SMTP Credentials
```

### Step 5: Store SMTP Credentials in Secrets Manager

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

### Step 6: Configure Moodle

Run the automated configuration script on your Moodle instance:

```bash
# Via SSM Session Manager
aws ssm start-session --target i-INSTANCE_ID

# Run the configuration script
sudo bash /tmp/configure-moodle-ses-email.sh

# Or download and run from S3
aws s3 cp s3://moodle-scripts-{account}-{region}/configure-moodle-ses-email.sh /tmp/
sudo chmod +x /tmp/configure-moodle-ses-email.sh
sudo /tmp/configure-moodle-ses-email.sh
```

---

## 🔍 Verification & Testing

### 1. Verify Network Connectivity

```bash
# Test DNS resolution
nslookup email-smtp.ca-central-1.amazonaws.com

# Test port 587 connectivity
timeout 10 bash -c 'cat < /dev/null > /dev/tcp/email-smtp.ca-central-1.amazonaws.com/587'
echo $?  # Should return 0 if successful

# Test with netcat
nc -zv email-smtp.ca-central-1.amazonaws.com 587
```

### 2. Verify Security Group Rules

```bash
# Get instance security group
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

SG_ID=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text)

# Check egress rules for SMTP ports
aws ec2 describe-security-groups \
  --group-ids $SG_ID \
  --query "SecurityGroups[0].IpPermissionsEgress[?ToPort==\`587\` || ToPort==\`465\`]"
```

### 3. Verify VPC Endpoint (if enabled)

```bash
# List VPC endpoints
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ca-central-1.email-smtp" \
  --query "VpcEndpoints[*].[VpcEndpointId,State,PrivateDnsEnabled]" \
  --output table

# Verify private DNS is enabled
# Should show: PrivateDnsEnabled = true
```

### 4. Test Email Sending from Moodle

```bash
# Connect to Moodle instance
aws ssm start-session --target i-INSTANCE_ID

# Send test email via Moodle CLI
cd /app/moodle
sudo -u apache php admin/cli/adhoc_task.php --execute=\\core\\task\\send_email_task
```

### 5. Check Email Queue

```sql
-- Connect to Moodle database
mariadb -h DB_ENDPOINT -u moodleuser -p

-- Check email queue status
SELECT 
  COUNT(*) as total_emails,
  SUM(CASE WHEN status = 0 THEN 1 ELSE 0 END) as pending,
  SUM(CASE WHEN status = 1 THEN 1 ELSE 0 END) as sent,
  SUM(CASE WHEN status = 2 THEN 1 ELSE 0 END) as failed
FROM mdl_email_queue;

-- View recent emails
SELECT id, recipient, subject, status, FROM_UNIXTIME(timecreated) as created
FROM mdl_email_queue 
ORDER BY timecreated DESC 
LIMIT 10;
```

---

## 🐛 Troubleshooting

### Issue 1: "SMTP port 587 is not reachable"

**Possible Causes:**
1. Security group egress rules not applied
2. Network ACL blocking traffic
3. No NAT Gateway and no VPC Endpoint

**Solutions:**
```bash
# Check if VPC endpoint exists
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ca-central-1.email-smtp"

# If no endpoint, verify NAT Gateway exists
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available"

# Redeploy with VPC endpoint
cdk deploy --parameters CreateSesVpcEndpoint=true
```

### Issue 2: "Authentication failed" or "Invalid credentials"

**Possible Causes:**
1. SMTP credentials not created
2. Credentials not stored in Secrets Manager
3. Wrong username/password format

**Solutions:**
```bash
# Verify secret exists
aws secretsmanager describe-secret \
  --secret-id moodle/ses/smtp-credentials

# Retrieve and verify credentials
aws secretsmanager get-secret-value \
  --secret-id moodle/ses/smtp-credentials \
  --query SecretString \
  --output text | jq .

# Test credentials manually
openssl s_client -connect email-smtp.ca-central-1.amazonaws.com:587 -starttls smtp
# Then: AUTH LOGIN
# Then: base64(username)
# Then: base64(password)
```

### Issue 3: "Email address not verified"

**Cause:** SES is in sandbox mode

**Solution:**
```bash
# Check SES sending limits
aws ses get-send-quota

# Verify email address
aws ses verify-email-identity --email-address noreply@tsin.ca

# Request production access (removes sandbox restrictions)
# Go to: AWS Console > SES > Account Dashboard > Request Production Access
```

---

## 📊 Monitoring & Logging

### CloudWatch Metrics

Monitor SES email sending:

```bash
# View SES metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/SES \
  --metric-name Send \
  --dimensions Name=Region,Value=ca-central-1 \
  --start-time 2025-01-01T00:00:00Z \
  --end-time 2025-01-31T23:59:59Z \
  --period 3600 \
  --statistics Sum
```

### CloudWatch Logs

Check Moodle application logs:

```bash
# View Moodle logs
aws logs tail /aws/ec2/moodle --follow

# Filter for email-related errors
aws logs filter-log-events \
  --log-group-name /aws/ec2/moodle \
  --filter-pattern "email|smtp|ses"
```

---

## 💰 Cost Optimization

### With VPC Endpoint (Recommended)
- **VPC Endpoint:** ~$7.30/month (ca-central-1)
- **Data Transfer:** $0.01/GB
- **NAT Gateway:** $0 (not needed for email)
- **Total:** ~$7.30/month + data transfer

### Without VPC Endpoint
- **NAT Gateway:** ~$32.85/month per AZ
- **Data Transfer:** $0.045/GB
- **Total:** ~$65.70/month (2 AZs) + data transfer

**Savings with VPC Endpoint:** ~$58/month (~89% reduction)

---

## 🔐 Security Best Practices

1. ✅ **Use Port 587 (STARTTLS)** - Most secure and reliable
2. ✅ **Store credentials in Secrets Manager** - Never hardcode
3. ✅ **Enable VPC Endpoint** - Keep traffic private
4. ✅ **Restrict FROM addresses** - Use IAM conditions
5. ✅ **Monitor bounce rates** - Set up SNS notifications
6. ✅ **Request production access** - Remove sandbox limitations
7. ✅ **Verify domain with DKIM** - Improve deliverability

---

## 📚 Additional Resources

- [AWS SES SMTP Documentation](https://docs.aws.amazon.com/ses/latest/dg/send-email-smtp.html)
- [SES SMTP Credentials](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html)
- [VPC Endpoints for SES](https://docs.aws.amazon.com/ses/latest/dg/send-email-set-up-vpc-endpoints.html)
- [Moodle Email Configuration](https://docs.moodle.org/en/Email_setup)

---

## ✅ Deployment Checklist

- [ ] CDK stack synthesized successfully
- [ ] SES domain/email verified
- [ ] SMTP credentials created
- [ ] Credentials stored in Secrets Manager
- [ ] VPC endpoint created (or NAT Gateway verified)
- [ ] Security group rules applied
- [ ] Moodle configuration script executed
- [ ] Test email sent successfully
- [ ] Email queue monitored
- [ ] CloudWatch alarms configured
- [ ] Production access requested (if needed)

---

**Last Updated:** 2025-01-29  
**CDK Version:** 2.x  
**Region:** ca-central-1

