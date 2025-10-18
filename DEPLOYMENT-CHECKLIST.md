# Deployment Checklist - PHP-FPM Improvements

## Pre-Deployment Checks

### 1. Review Changes
- [ ] Review all changes in `lib/moodle-cdk-stack.ts`
- [ ] Verify PHP-FPM configuration is correct
- [ ] Verify Apache timeout settings
- [ ] Verify CloudWatch agent configuration
- [ ] Verify health check endpoint path changed to `/health.php`

```bash
git diff lib/moodle-cdk-stack.ts
```

### 2. Backup Current State
- [ ] Take snapshot of current RDS database
- [ ] Document current instance IDs
- [ ] Export current CloudFormation template

```bash
# Get current instance IDs
aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=*MoodleAutoScalingGroup*" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name]" \
  --output table

# Create RDS snapshot
aws rds create-db-snapshot \
  --db-instance-identifier moodlecdkstack-moodledbinstance* \
  --db-snapshot-identifier moodle-pre-php-improvements-$(date +%Y%m%d-%H%M%S)
```

### 3. Notify Users
- [ ] Schedule maintenance window
- [ ] Send notification to users
- [ ] Set up status page

---

## Deployment Steps

### Step 1: Synthesize CDK
```bash
cd C:/github/moodle-cdk0
cdk synth
```

**Expected output**: CloudFormation template generated successfully

**If errors**: Fix TypeScript errors and retry

---

### Step 2: Review Changes
```bash
cdk diff
```

**Review**:
- [ ] Launch template changes (PHP-FPM config, Apache config)
- [ ] Target group changes (health check path, deregistration delay)
- [ ] Auto-scaling policy additions
- [ ] CloudWatch alarm additions
- [ ] No unexpected deletions

---

### Step 3: Deploy
```bash
cdk deploy --require-approval never
```

**Expected duration**: 10-15 minutes

**What happens**:
1. CloudFormation updates stack
2. New launch template version created
3. Auto-scaling group updated
4. **Instances will be replaced** (rolling update)
5. New instances will have PHP-FPM configuration
6. CloudWatch alarms created

---

### Step 4: Monitor Deployment

#### Watch CloudFormation Events
```bash
# In separate terminal
watch -n 5 'aws cloudformation describe-stack-events \
  --stack-name MoodleCdkStack \
  --max-items 10 \
  --query "StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId]" \
  --output table'
```

#### Watch Instance Replacement
```bash
# In separate terminal
watch -n 10 'aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=*MoodleAutoScalingGroup*" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name,LaunchTime]" \
  --output table'
```

#### Watch Target Health
```bash
# In separate terminal
watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names "*MoodleTargetGroup*" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text) \
  --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]" \
  --output table'
```

---

## Post-Deployment Verification

### Step 5: Verify Health Checks

#### Test Health Endpoint
```bash
# Test HTTP health endpoint
curl -s https://elearning.tsin.ca/health.php

# Expected output:
# OK (PHP 8.3 OK, DB OK, Apache modules loaded) [45.23ms]
```

**Checklist**:
- [ ] Returns HTTP 200
- [ ] Shows "OK" status
- [ ] Shows PHP version
- [ ] Shows DB OK
- [ ] Response time < 1000ms

---

### Step 6: Verify PHP-FPM Configuration

```bash
# Get new instance ID
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=*MoodleAutoScalingGroup*" \
  "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# Check PHP-FPM configuration
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "echo === PHP-FPM CONFIG ===",
    "grep -E \"pm.max_children|pm.start_servers|request_terminate_timeout\" /etc/php-fpm.d/www.conf",
    "echo === PHP-FPM PROCESSES ===",
    "ps aux | grep php-fpm | grep -v grep | wc -l",
    "echo === PHP-FPM STATUS ===",
    "systemctl status php-fpm | head -10"
  ]' \
  --query "Command.CommandId" \
  --output text
```

**Expected**:
- [ ] `pm.max_children = 50`
- [ ] `pm.start_servers = 10`
- [ ] `request_terminate_timeout = 300`
- [ ] PHP-FPM process count: 10-20
- [ ] PHP-FPM status: active (running)

---

### Step 7: Verify Apache Configuration

```bash
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "echo === APACHE CONFIG ===",
    "grep -E \"ProxyTimeout|Timeout\" /etc/httpd/conf.d/moodle.conf",
    "echo === APACHE STATUS ===",
    "systemctl status httpd | head -10"
  ]' \
  --query "Command.CommandId" \
  --output text
```

**Expected**:
- [ ] `ProxyTimeout 300`
- [ ] `Timeout 300`
- [ ] Apache status: active (running)

---

### Step 8: Verify CloudWatch Agent

```bash
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "echo === CLOUDWATCH AGENT STATUS ===",
    "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a query -m ec2 -c default -s"
  ]' \
  --query "Command.CommandId" \
  --output text
```

**Expected**:
- [ ] Status: running
- [ ] Config: /opt/aws/amazon-cloudwatch-agent/etc/config.json

---

### Step 9: Verify CloudWatch Logs

```bash
# Check log groups exist
aws logs describe-log-groups \
  --log-group-name-prefix /aws/ec2/moodle \
  --query "logGroups[*].logGroupName" \
  --output table

# Tail logs
aws logs tail /aws/ec2/moodle --follow --since 5m
```

**Expected log streams**:
- [ ] `{instance_id}/apache-error`
- [ ] `{instance_id}/moodle-error`
- [ ] `{instance_id}/php-fpm-slow`
- [ ] `{instance_id}/php-fpm-error`

---

### Step 10: Verify CloudWatch Alarms

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix MoodleCdkStack \
  --query "MetricAlarms[*].[AlarmName,StateValue,MetricName,Threshold]" \
  --output table
```

**Expected alarms**:
- [ ] HighCpuAlarm (OK)
- [ ] UnhealthyTargetAlarm (OK)
- [ ] HighResponseTimeAlarm (OK)
- [ ] High5xxAlarm (OK)

---

### Step 11: Verify Auto-Scaling Policies

```bash
aws autoscaling describe-policies \
  --auto-scaling-group-name $(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName" \
    --output text) \
  --query "ScalingPolicies[*].[PolicyName,PolicyType,TargetTrackingConfiguration.TargetValue]" \
  --output table
```

**Expected policies**:
- [ ] CpuScaling (TargetTracking, 70%)
- [ ] RequestCountScaling (TargetTracking, 1000 req/min)

---

### Step 12: Test Application

#### Test Homepage
```bash
curl -s -o /dev/null -w "HTTP %{http_code} - %{time_total}s\n" https://elearning.tsin.ca/
```

**Expected**:
- [ ] HTTP 200
- [ ] Response time < 3 seconds

#### Test Login
- [ ] Navigate to https://elearning.tsin.ca/
- [ ] Login with admin credentials
- [ ] Verify dashboard loads
- [ ] Check for any errors

#### Test File Upload
- [ ] Upload a test file
- [ ] Verify file is saved
- [ ] Check EFS mount is working

---

## Performance Testing

### Step 13: Load Test (Optional)

```bash
# Simple load test with Apache Bench
ab -n 1000 -c 10 https://elearning.tsin.ca/

# Or use hey
hey -n 1000 -c 10 https://elearning.tsin.ca/
```

**Monitor during load test**:
- [ ] PHP-FPM process count increases
- [ ] No 504 errors
- [ ] Response time stays < 5 seconds
- [ ] Auto-scaling triggers if needed

---

## Rollback Plan

### If Issues Occur

#### Option 1: Rollback CDK Deployment
```bash
# Revert git changes
git revert HEAD

# Deploy previous version
cdk deploy
```

#### Option 2: Manual Instance Replacement
```bash
# Terminate new instances
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id $NEW_INSTANCE_ID \
  --no-should-decrement-desired-capacity

# ASG will launch replacement with old launch template
```

#### Option 3: Restore from Snapshot
```bash
# Restore RDS from snapshot
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier moodle-restored \
  --db-snapshot-identifier moodle-pre-php-improvements-*
```

---

## Success Criteria

### All Checks Must Pass

- [x] CDK deployment completed successfully
- [ ] All instances healthy in target group
- [ ] Health endpoint returns HTTP 200
- [ ] PHP-FPM configured with 50 max children
- [ ] Apache timeout set to 300 seconds
- [ ] CloudWatch agent running
- [ ] CloudWatch logs streaming
- [ ] CloudWatch alarms created and OK
- [ ] Auto-scaling policies active
- [ ] Application accessible at https://elearning.tsin.ca/
- [ ] No 504 errors
- [ ] Response time < 3 seconds
- [ ] Login works
- [ ] File upload works

---

## Post-Deployment Monitoring

### First 24 Hours

#### Monitor Every Hour
```bash
# Check alarms
aws cloudwatch describe-alarms --state-value ALARM

# Check target health
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# Check PHP-FPM process count
aws ssm send-command --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["ps aux | grep php-fpm | grep -v grep | wc -l"]'
```

#### Watch for Issues
- [ ] No 504 Gateway Timeout errors
- [ ] No PHP-FPM exhaustion errors
- [ ] No unhealthy targets
- [ ] Response time < 5 seconds
- [ ] No CloudWatch alarms firing

---

## Troubleshooting

### Issue: Health Check Failing

**Symptoms**: Target shows unhealthy in target group

**Check**:
```bash
# Test health endpoint from instance
aws ssm send-command --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["curl -s http://localhost/health.php"]'
```

**Possible causes**:
- PHP-FPM not running
- Apache not running
- Database connection failed
- Health.php file missing

---

### Issue: 504 Gateway Timeout

**Symptoms**: Users see 504 error

**Check**:
```bash
# Check PHP-FPM process count
aws ssm send-command --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "ps aux | grep php-fpm | grep -v grep | wc -l",
    "tail -50 /var/log/httpd/error_log | grep proxy_fcgi"
  ]'
```

**Possible causes**:
- PHP-FPM process pool exhausted (should not happen with 50 max)
- Database slow queries
- EFS mount issues

---

### Issue: Auto-Scaling Not Triggering

**Symptoms**: High load but no new instances

**Check**:
```bash
# Check scaling policies
aws autoscaling describe-policies --auto-scaling-group-name $ASG_NAME

# Check CloudWatch metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value=$ASG_NAME \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

**Possible causes**:
- CPU not reaching 70% threshold
- Request count not reaching 1000/min
- Cooldown period active

---

## Sign-Off

### Deployment Team
- [ ] Deployment completed by: ________________
- [ ] Date/Time: ________________
- [ ] All checks passed: Yes / No
- [ ] Issues encountered: ________________

### Approval
- [ ] Approved by: ________________
- [ ] Date/Time: ________________

