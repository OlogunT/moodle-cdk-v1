# CDK PHP-FPM & Monitoring Improvements - Implementation Summary

## Overview

This document summarizes the improvements made to the Moodle CDK stack to prevent PHP-FPM process pool exhaustion and improve monitoring/reliability.

---

## 1. PHP-FPM Production Configuration ✅

### What Was Added

**File**: `/etc/php-fpm.d/www.conf`

**Configuration**:
```ini
[www]
user = apache
group = apache
listen = /run/php-fpm/www.sock

; Process pool management - optimized for production
pm = dynamic
pm.max_children = 50          # Maximum PHP-FPM processes
pm.start_servers = 10         # Start with 10 processes
pm.min_spare_servers = 5      # Keep at least 5 idle
pm.max_spare_servers = 20     # Keep at most 20 idle
pm.max_requests = 1000        # Recycle after 1000 requests

; Timeouts
request_terminate_timeout = 300    # Kill requests after 5 minutes
request_slowlog_timeout = 10s      # Log slow requests

; Logging
slowlog = /var/log/php-fpm/www-slow.log
catch_workers_output = yes

; Status monitoring
pm.status_path = /php-fpm-status
ping.path = /php-fpm-ping
```

### Why This Helps

- **Prevents process pool exhaustion**: `pm.max_children = 50` allows up to 50 concurrent PHP requests
- **Automatic scaling**: `pm = dynamic` scales processes based on demand
- **Memory leak protection**: `pm.max_requests = 1000` recycles processes
- **Timeout protection**: `request_terminate_timeout = 300` kills hung requests
- **Monitoring**: Status and ping endpoints for health checks

---

## 2. PHP Configuration for Moodle ✅

### What Was Added

**File**: `/etc/php.d/99-moodle.ini`

**Configuration**:
```ini
max_execution_time = 300      # 5 minutes for long operations
max_input_time = 300
memory_limit = 256M           # Sufficient for Moodle
post_max_size = 512M          # Large file uploads
upload_max_filesize = 512M
max_input_vars = 5000         # Moodle forms can be large
```

### Why This Helps

- **Prevents timeouts**: 300 second execution time for backups, upgrades
- **Supports large files**: 512MB upload limit for course materials
- **Moodle compatibility**: Meets Moodle's recommended settings

---

## 3. Apache Timeout & Proxy Configuration ✅

### What Was Added

**File**: `/etc/httpd/conf.d/moodle.conf`

**Configuration**:
```apache
<VirtualHost *:80>
  # PHP-FPM proxy configuration
  <FilesMatch \.php$>
    SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
  </FilesMatch>

  # Timeout settings to prevent 504 errors
  ProxyTimeout 300
  Timeout 300

  # Security headers
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
```

### Why This Helps

- **Prevents 504 Gateway Timeout**: `ProxyTimeout 300` matches PHP timeout
- **Proper PHP-FPM integration**: Uses Unix socket for better performance
- **Security**: Adds security headers

---

## 4. Advanced Health Check ✅

### What Was Added

**File**: `/app/moodle/health.php`

**Tests**:
1. ✅ PHP is executing (tests Apache → PHP-FPM communication)
2. ✅ PHP-FPM SAPI detection
3. ✅ Response time < 5 seconds
4. ✅ Memory usage monitoring
5. ✅ Database connectivity test (if config exists)
6. ✅ Apache module detection

**Response Format**:
```
HTTP 200: OK (PHP 8.3 OK, DB OK, Apache modules loaded) [45.23ms]
HTTP 503: UNHEALTHY: DB connection failed, Response too slow: 6.2s
```

### Why This Helps

- **Real health check**: Tests actual PHP-FPM processing, not just static file
- **Database validation**: Catches DB connection issues early
- **Performance monitoring**: Reports response time
- **Detailed diagnostics**: Shows what's working and what's not

---

## 5. CloudWatch Agent Configuration ✅

### What Was Added

**File**: `/opt/aws/amazon-cloudwatch-agent/etc/config.json`

**Logs Collected**:
- `/var/log/httpd/error_log` → `/aws/ec2/moodle/{instance_id}/apache-error`
- `/var/log/httpd/moodle_error.log` → `/aws/ec2/moodle/{instance_id}/moodle-error`
- `/var/log/php-fpm/www-slow.log` → `/aws/ec2/moodle/{instance_id}/php-fpm-slow`
- `/var/log/php-fpm/www-error.log` → `/aws/ec2/moodle/{instance_id}/php-fpm-error`

**Metrics Collected**:
- CPU usage (idle, iowait)
- Memory usage (percent)
- PHP-FPM process count

### Why This Helps

- **Centralized logging**: All logs in CloudWatch for easy troubleshooting
- **Performance monitoring**: Track CPU, memory, process count
- **Slow query detection**: PHP-FPM slow log catches performance issues
- **Historical data**: Analyze trends over time

---

## 6. Improved Target Group Health Checks ✅

### What Was Changed

**Before**:
```typescript
healthCheck: {
  path: '/health',              // Static file
  interval: cdk.Duration.seconds(15),
  timeout: cdk.Duration.seconds(6),
  unhealthyThresholdCount: 5,   // Slow to detect failures
}
```

**After**:
```typescript
healthCheck: {
  path: '/health.php',          // PHP health check
  interval: cdk.Duration.seconds(10),  // More frequent
  timeout: cdk.Duration.seconds(5),
  unhealthyThresholdCount: 2,   // Faster detection
}
deregistrationDelay: cdk.Duration.seconds(300),  // Connection draining
```

### Why This Helps

- **Real health check**: Tests PHP-FPM, not just Apache
- **Faster detection**: 20 seconds to detect unhealthy (was 75 seconds)
- **Connection draining**: 5 minutes for graceful shutdown
- **Better user experience**: Requests complete before instance removal

---

## 7. Auto-Scaling Policies ✅

### What Was Added

**CPU-based scaling**:
```typescript
autoScalingGroup.scaleOnCpuUtilization('CpuScaling', {
  targetUtilizationPercent: 70,
  cooldown: cdk.Duration.minutes(5),
});
```

**Request count scaling**:
```typescript
autoScalingGroup.scaleOnRequestCount('RequestCountScaling', {
  targetRequestsPerMinute: 1000,
  targetGroup: targetGroup,
});
```

### Why This Helps

- **Automatic scaling**: Adds instances when CPU > 70% or requests > 1000/min
- **Prevents overload**: Scales before hitting limits
- **Cost optimization**: Scales down during low traffic

---

## 8. CloudWatch Alarms ✅

### What Was Added

**1. High CPU Alarm**
- Threshold: 80%
- Evaluation: 2 consecutive periods
- Action: Alert operations team

**2. Unhealthy Target Alarm**
- Threshold: 1 unhealthy target
- Evaluation: 2 consecutive periods
- Action: Alert operations team

**3. High Response Time Alarm**
- Threshold: 10 seconds
- Evaluation: 2 consecutive periods
- Action: Alert operations team (504 timeout indicator)

**4. High 5xx Error Alarm**
- Threshold: 10 errors per minute
- Evaluation: 1 period
- Action: Alert operations team

### Why This Helps

- **Proactive monitoring**: Catch issues before users complain
- **Early warning**: High response time predicts 504 timeouts
- **Automated alerts**: No need to manually check dashboards
- **Root cause analysis**: Correlate alarms with logs

---

## Summary of Changes

| Component | Before | After | Impact |
|-----------|--------|-------|--------|
| **PHP-FPM Config** | Default (5 processes) | 50 max processes | ✅ Prevents exhaustion |
| **PHP Timeout** | 30 seconds | 300 seconds | ✅ Prevents timeouts |
| **Apache Timeout** | 60 seconds | 300 seconds | ✅ Prevents 504 errors |
| **Health Check** | Static file | PHP + DB test | ✅ Real health validation |
| **Health Check Interval** | 15 seconds | 10 seconds | ✅ Faster detection |
| **Unhealthy Threshold** | 5 failures | 2 failures | ✅ Faster response |
| **CloudWatch Logs** | None | 4 log streams | ✅ Centralized logging |
| **CloudWatch Metrics** | None | CPU, Mem, Processes | ✅ Performance monitoring |
| **Auto-Scaling** | Manual only | CPU + Request count | ✅ Automatic scaling |
| **Alarms** | None | 4 critical alarms | ✅ Proactive alerts |
| **Connection Draining** | None | 300 seconds | ✅ Graceful shutdown |

---

## Deployment Instructions

### 1. Review Changes
```bash
git diff lib/moodle-cdk-stack.ts
```

### 2. Synthesize CDK
```bash
cdk synth
```

### 3. Deploy Changes
```bash
cdk deploy
```

### 4. Verify Deployment
```bash
# Check health endpoint
curl -s https://elearning.tsin.ca/health.php

# Check CloudWatch logs
aws logs tail /aws/ec2/moodle --follow

# Check alarms
aws cloudwatch describe-alarms --alarm-name-prefix Moodle
```

---

## Expected Results

After deployment:

✅ **No more PHP-FPM exhaustion**: 50 processes can handle high load
✅ **No more 504 timeouts**: Proper timeout configuration
✅ **Better health checks**: Real PHP-FPM validation
✅ **Automatic scaling**: Handles traffic spikes
✅ **Proactive monitoring**: Alerts before failures
✅ **Centralized logs**: Easy troubleshooting
✅ **Graceful shutdowns**: No dropped requests

---

## Monitoring After Deployment

### Check PHP-FPM Process Count
```bash
aws ssm send-command \
  --instance-ids i-0eab4573101db727a \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["ps aux | grep php-fpm | grep -v grep | wc -l"]'
```

### Check CloudWatch Metrics
```bash
aws cloudwatch get-metric-statistics \
  --namespace Moodle \
  --metric-name PHP_FPM_PROCESSES \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

### Check Alarms
```bash
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --query 'MetricAlarms[*].[AlarmName,StateReason]' \
  --output table
```

---

## Next Steps

1. ✅ **Deploy the changes**: `cdk deploy`
2. ✅ **Monitor for 24 hours**: Watch CloudWatch metrics and alarms
3. ✅ **Load test**: Simulate high traffic to verify scaling
4. ✅ **Tune if needed**: Adjust `pm.max_children` based on actual load
5. ✅ **Set up SNS notifications**: Connect alarms to email/Slack

---

## Rollback Plan

If issues occur after deployment:

```bash
# Rollback to previous version
cdk deploy --rollback

# Or manually revert changes
git revert HEAD
cdk deploy
```

---

## Success Criteria

- [ ] No 504 Gateway Timeout errors
- [ ] Health checks passing consistently
- [ ] PHP-FPM process count < 50
- [ ] Response time < 2 seconds average
- [ ] Auto-scaling triggers during load
- [ ] CloudWatch logs streaming
- [ ] Alarms configured and working
- [ ] No PHP-FPM exhaustion errors in logs

