# Email Testing Guide for SES Integration

## 📧 Overview

This guide provides comprehensive instructions for testing AWS SES email delivery after deploying the SES configuration to your Moodle infrastructure.

---

## 🚀 Quick Start

### Option 1: Remote Testing (Recommended)

Run from your local machine using PowerShell:

```powershell
# Test all instances automatically
.\scripts\test-ses-email-remote.ps1

# Test specific instance
.\scripts\test-ses-email-remote.ps1 -InstanceId i-1234567890abcdef0

# Test without sending email
.\scripts\test-ses-email-remote.ps1 -SendTestEmail:$false
```

### Option 2: On-Instance Testing

Connect to instance and run locally:

```bash
# Connect via SSM
aws ssm start-session --target i-INSTANCE_ID

# Run test script
sudo bash /tmp/test-ses-email-delivery.sh
```

---

## 📋 Test Phases

The email delivery test performs **8 comprehensive phases**:

### Phase 1: Network Connectivity Tests ✅
- DNS resolution for SES endpoint
- Port 587 (STARTTLS) connectivity
- Port 443 (HTTPS) connectivity

### Phase 2: Configuration Verification ✅
- Moodle config.php exists
- SMTP host configured
- SMTP security (TLS) configured
- SMTP port (587) configured
- SMTP username configured
- SMTP password configured

### Phase 3: SES Service Verification ✅
- SES API accessible
- SES sending quota check
- Sandbox vs Production mode
- Verified email identities

### Phase 4: SMTP Authentication Test ✅
- SMTP credentials exist in Secrets Manager
- SMTP connection test
- STARTTLS negotiation

### Phase 5: Moodle Email Queue Test ✅
- Email queue table exists
- Queue statistics (pending, sent, failed)

### Phase 6: Send Test Email ✅
- Create test email via Moodle API
- Queue email for delivery
- Verify email queued successfully

### Phase 7: Process Email Queue ✅
- Run Moodle cron task
- Process pending emails
- Send emails via SES

### Phase 8: Verify Email Delivery ✅
- Check recent email queue entries
- Verify email status (sent/failed)
- Display delivery statistics

---

## 🔍 Expected Test Results

### All Tests Passing ✅

```
=== TEST SUMMARY ===

Total Tests: 15
Passed: 15
Failed: 0

🎉 ALL TESTS PASSED!

✅ SES email delivery is working correctly

Next steps:
1. Check your email inbox for the test email
2. Monitor the email queue for any failures
3. Set up CloudWatch alarms for email bounces
4. Request SES production access if still in sandbox mode
```

### Partial Failures ⚠️

Common scenarios and solutions:

#### Scenario 1: Network Connectivity Failed
```
✗ FAILED: Port 587 (STARTTLS) Connectivity
```

**Cause:** Security group or VPC endpoint issue  
**Solution:**
```bash
# Check security group egress rules
aws ec2 describe-security-groups --group-ids sg-XXXXXXXX \
  --query "SecurityGroups[0].IpPermissionsEgress[?ToPort==\`587\`]"

# Verify VPC endpoint
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ca-central-1.email-smtp"
```

#### Scenario 2: Configuration Missing
```
✗ FAILED: SMTP User configured
✗ FAILED: SMTP Password configured
```

**Cause:** Moodle not configured with SES credentials  
**Solution:**
```bash
# Run configuration script
sudo bash /tmp/configure-moodle-ses-email.sh
```

#### Scenario 3: SES Sandbox Mode
```
⚠ SES is in SANDBOX mode - only verified addresses can receive emails
```

**Cause:** SES account in sandbox (default)  
**Solution:**
1. Verify recipient email addresses
2. Request production access: https://console.aws.amazon.com/ses/home#/account

---

## 📊 Interpreting Test Output

### Network Tests

```bash
[TEST 1] DNS Resolution for SES Endpoint
✓ PASSED

[TEST 2] Port 587 (STARTTLS) Connectivity
✓ PASSED

[TEST 3] Port 443 (HTTPS) Connectivity
✓ PASSED
```

**Meaning:** Network connectivity to SES is working correctly

### Configuration Tests

```bash
[TEST 4] Moodle config.php exists
✓ PASSED

[TEST 5] SMTP Host configured in Moodle
✓ PASSED

[TEST 6] SMTP Security configured (TLS)
✓ PASSED
```

**Meaning:** Moodle is properly configured to use SES

### Email Queue Tests

```bash
Email Queue Statistics:
+---------------+---------+------+--------+
| total_emails  | pending | sent | failed |
+---------------+---------+------+--------+
|            5  |       0 |    5 |      0 |
+---------------+---------+------+--------+
```

**Meaning:**
- **total_emails:** Total emails in queue
- **pending:** Emails waiting to be sent
- **sent:** Successfully sent emails
- **failed:** Failed email deliveries

### Test Email Output

```bash
[TEST 12] Send Test Email
✓ Test email queued successfully
Check your inbox: admin@example.com
✓ PASSED
```

**Action:** Check the specified email inbox for test email

---

## 🛠️ Manual Testing

### Test 1: Send Email via Moodle CLI

```bash
# Connect to instance
aws ssm start-session --target i-INSTANCE_ID

# Send test email
cd /app/moodle
sudo -u apache php -r "
  define('CLI_SCRIPT', true);
  require_once('/app/moodle/config.php');
  require_once(\$CFG->libdir.'/moodlelib.php');
  
  \$admin = \$DB->get_record('user', array('username' => 'moodle-admin'));
  \$result = email_to_user(\$admin, \$admin, 'Test Email', 'This is a test');
  
  echo \$result ? 'Email sent successfully' : 'Email failed';
"
```

### Test 2: Check Email Queue

```sql
-- Connect to database
mariadb -h DB_ENDPOINT -u moodleuser -p

-- View email queue
SELECT id, recipient, subject, 
       CASE status 
         WHEN 0 THEN 'Pending'
         WHEN 1 THEN 'Sent'
         WHEN 2 THEN 'Failed'
       END as status,
       FROM_UNIXTIME(timecreated) as created
FROM mdl_email_queue 
ORDER BY timecreated DESC 
LIMIT 10;
```

### Test 3: Process Email Queue Manually

```bash
# Run Moodle cron task
cd /app/moodle
sudo -u apache php admin/cli/adhoc_task.php --execute=\\core\\task\\send_email_task
```

### Test 4: Test SMTP Connection with OpenSSL

```bash
# Test SMTP connection
openssl s_client -connect email-smtp.ca-central-1.amazonaws.com:587 -starttls smtp

# Expected output:
# 220 email-smtp.amazonaws.com ESMTP SimpleEmailService...
# CONNECTED(00000003)
```

### Test 5: Check SES Sending Statistics

```bash
# Get SES quota
aws ses get-send-quota --region ca-central-1

# Get send statistics (last 2 weeks)
aws ses get-send-statistics --region ca-central-1

# List verified identities
aws ses list-verified-email-addresses --region ca-central-1
```

---

## 📈 Monitoring Email Delivery

### CloudWatch Metrics

```bash
# View SES send metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/SES \
  --metric-name Send \
  --dimensions Name=Region,Value=ca-central-1 \
  --start-time 2025-01-01T00:00:00Z \
  --end-time 2025-01-31T23:59:59Z \
  --period 3600 \
  --statistics Sum

# View bounce rate
aws cloudwatch get-metric-statistics \
  --namespace AWS/SES \
  --metric-name Bounce \
  --dimensions Name=Region,Value=ca-central-1 \
  --start-time 2025-01-01T00:00:00Z \
  --end-time 2025-01-31T23:59:59Z \
  --period 3600 \
  --statistics Sum
```

### Moodle Logs

```bash
# Check Moodle error logs
tail -f /var/log/httpd/error_log | grep -i email

# Check Moodle access logs
tail -f /var/log/httpd/access_log

# Check system logs
journalctl -u httpd -f
```

### SES Console

1. Go to: https://console.aws.amazon.com/ses/home
2. Navigate to: **Sending Statistics**
3. View:
   - Sends
   - Bounces
   - Complaints
   - Delivery rate

---

## 🐛 Troubleshooting Failed Tests

### Issue: "Port 587 not reachable"

**Diagnosis:**
```bash
# Run diagnostic script
sudo bash /tmp/diagnose-ses-email.sh

# Check security group
aws ec2 describe-security-groups --group-ids sg-XXXXXXXX
```

**Solutions:**
1. Verify security group egress rules allow port 587
2. Check VPC endpoint exists and is available
3. Verify NAT Gateway if not using VPC endpoint
4. Check network ACLs

### Issue: "SMTP authentication failed"

**Diagnosis:**
```bash
# Check credentials in Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id moodle/ses/smtp-credentials \
  --query SecretString \
  --output text | jq .
```

**Solutions:**
1. Verify SMTP credentials are correct
2. Regenerate SMTP credentials in SES Console
3. Update credentials in Secrets Manager
4. Re-run configuration script

### Issue: "Email not verified"

**Diagnosis:**
```bash
# Check verified identities
aws ses list-verified-email-addresses --region ca-central-1
```

**Solutions:**
1. Verify sender email address in SES
2. Check email inbox for verification link
3. Request production access to remove sandbox restrictions

### Issue: "Email queued but not sent"

**Diagnosis:**
```sql
-- Check email queue
SELECT * FROM mdl_email_queue WHERE status = 2 ORDER BY timecreated DESC LIMIT 5;
```

**Solutions:**
1. Check Moodle cron is running
2. Verify SMTP configuration in database
3. Check Moodle error logs
4. Manually process email queue

---

## ✅ Post-Testing Checklist

After successful testing:

- [ ] Test email received in inbox
- [ ] Email queue processing correctly
- [ ] No failed emails in queue
- [ ] SES sending statistics show successful sends
- [ ] CloudWatch metrics showing email activity
- [ ] Moodle error logs clean (no email errors)
- [ ] Production access requested (if needed)
- [ ] CloudWatch alarms configured
- [ ] Email bounce handling configured
- [ ] Documentation updated with any findings

---

## 📚 Additional Resources

- **Configuration Guide:** `docs/SES-EMAIL-CONFIGURATION.md`
- **Quick Start:** `docs/SES-QUICK-START.md`
- **Diagnostic Script:** `scripts/diagnose-ses-email.sh`
- **AWS SES Documentation:** https://docs.aws.amazon.com/ses/
- **Moodle Email Setup:** https://docs.moodle.org/en/Email_setup

---

## 🆘 Getting Help

If tests continue to fail:

1. **Run full diagnostic:**
   ```bash
   sudo bash /tmp/diagnose-ses-email.sh > /tmp/diagnostic-output.txt
   ```

2. **Collect logs:**
   ```bash
   # Moodle logs
   tail -100 /var/log/httpd/error_log > /tmp/moodle-errors.txt
   
   # Email queue
   mariadb -h DB_HOST -u USER -p -D DB_NAME -e \
     "SELECT * FROM mdl_email_queue ORDER BY timecreated DESC LIMIT 20" \
     > /tmp/email-queue.txt
   ```

3. **Check AWS resources:**
   ```bash
   # VPC endpoint
   aws ec2 describe-vpc-endpoints --region ca-central-1
   
   # Security groups
   aws ec2 describe-security-groups --region ca-central-1
   
   # SES statistics
   aws ses get-send-statistics --region ca-central-1
   ```

4. **Review documentation** in `docs/` folder

---

**Last Updated:** 2025-01-29  
**Region:** ca-central-1  
**Moodle Version:** 5.0

