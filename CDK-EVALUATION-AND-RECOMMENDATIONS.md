# CDK Implementation Evaluation & Recommendations

## Executive Summary

The current CDK implementation has **solid infrastructure foundations** but lacks **operational visibility and PHP-FPM resource management**. The PHP-FPM process pool exhaustion issue could have been prevented with proper monitoring, configuration, and health checks.

---

## Critical Issues Found

### 1. ❌ **Inadequate Health Checks**
**Problem**: Health check only tests `/health` endpoint, not actual Moodle functionality
```typescript
healthCheck: {
  enabled: true,
  healthyHttpCodes: '200',
  path: '/health',           // ← Only tests static endpoint
  interval: cdk.Duration.seconds(15),
  timeout: cdk.Duration.seconds(6),
}
```

**Impact**: 
- Instances marked "healthy" even when PHP-FPM is exhausted
- ALB continues routing traffic to broken instances
- Users experience timeouts while infrastructure appears healthy

**Recommendation**: Implement multi-level health checks
```typescript
// Primary: Static health endpoint (fast)
// Secondary: PHP processing test (detects PHP-FPM issues)
// Tertiary: Database connectivity test (detects DB issues)
```

---

### 2. ❌ **No PHP-FPM Configuration**
**Problem**: PHP-FPM installed but never configured for production load
```bash
yum install -y ... php-fpm ...
systemctl restart php-fpm || true
# ← No configuration of process pool, timeouts, or limits
```

**Impact**:
- Default PHP-FPM pool size too small for production
- No request timeout configuration
- Process pool exhaustion under load
- No monitoring of process count

**Recommendation**: Configure PHP-FPM for production
```bash
# /etc/php-fpm.d/www.conf
pm = dynamic
pm.max_children = 50        # Increase from default ~5
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
request_terminate_timeout = 300
```

---

### 3. ❌ **No CloudWatch Monitoring**
**Problem**: CloudWatch agent installed but never configured
```typescript
iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
// ← Agent installed but no config deployed
```

**Impact**:
- No visibility into PHP-FPM process count
- No CPU/memory metrics
- No Apache error rate tracking
- No early warning of resource exhaustion

**Recommendation**: Deploy CloudWatch agent configuration
```json
{
  "metrics": {
    "namespace": "Moodle",
    "metrics_collected": {
      "processes": {
        "measurement": [
          {"name": "running", "rename": "php_fpm_processes"}
        ],
        "metrics_collection_interval": 60,
        "pattern": "php-fpm"
      },
      "cpu": {"measurement": ["cpu_usage_idle"], "metrics_collection_interval": 60},
      "mem": {"measurement": ["mem_used_percent"], "metrics_collection_interval": 60}
    }
  }
}
```

---

### 4. ❌ **No CloudWatch Alarms**
**Problem**: No alarms defined for critical metrics
```typescript
// No alarms for:
// - High CPU usage
// - High memory usage
// - PHP-FPM process count
// - ALB target unhealthy
// - RDS connection errors
```

**Impact**:
- Issues go unnoticed until users complain
- No automated remediation
- Slow incident response

**Recommendation**: Add CloudWatch alarms
```typescript
// CPU alarm
new cloudwatch.Alarm(this, 'HighCpuAlarm', {
  metric: ec2Instance.metricCpuUtilization(),
  threshold: 80,
  evaluationPeriods: 2,
  alarmDescription: 'Alert when CPU > 80%',
});

// PHP-FPM process count alarm
new cloudwatch.Alarm(this, 'PhpFpmProcessAlarm', {
  metric: new cloudwatch.Metric({
    namespace: 'Moodle',
    metricName: 'php_fpm_processes',
    statistic: 'Average',
  }),
  threshold: 40,  // Alert if approaching max
  evaluationPeriods: 2,
});
```

---

### 5. ❌ **Insufficient ASG Grace Period**
**Problem**: 45-minute grace period too long for detecting PHP-FPM issues
```typescript
healthCheck: autoscaling.HealthCheck.elb({
  grace: cdk.Duration.minutes(45),  // ← Too long
}),
```

**Impact**:
- New instances get 45 minutes before health checks matter
- PHP-FPM issues not detected during this window
- Users affected for extended period

**Recommendation**: Reduce grace period and add lifecycle hooks
```typescript
healthCheck: autoscaling.HealthCheck.elb({
  grace: cdk.Duration.minutes(10),  // Reduce to 10 minutes
}),
```

---

### 6. ❌ **No Scaling Policies**
**Problem**: ASG has fixed capacity, no auto-scaling
```typescript
const autoScalingGroup = new autoscaling.AutoScalingGroup(this, 'MoodleAutoScalingGroup', {
  minCapacity: 2,
  maxCapacity: 4,
  desiredCapacity: 2,
  // ← No scaling policies defined
});
```

**Impact**:
- Can't handle traffic spikes
- Manual intervention required to scale
- Potential for cascading failures

**Recommendation**: Add scaling policies
```typescript
autoScalingGroup.scaleOnCpuUtilization('CpuScaling', {
  targetUtilizationPercent: 70,
});

autoScalingGroup.scaleOnRequestCount('RequestScaling', {
  targetRequestsPerMinute: 1000,
});
```

---

### 7. ⚠️ **Incomplete CloudWatch Logs Integration**
**Problem**: Log groups created but not used by instances
```typescript
const moodleLogGroup = new logs.LogGroup(this, 'MoodleLogGroup', {
  logGroupName: '/aws/ec2/moodle',
  retention: logs.RetentionDays.ONE_WEEK,
});
// ← Created but never referenced in user data
```

**Impact**:
- Logs not centralized
- Hard to troubleshoot issues
- No log-based alarms possible

**Recommendation**: Configure CloudWatch Logs agent
```bash
# Deploy CloudWatch agent config to send logs
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json
```

---

## Medium Priority Issues

### 8. ⚠️ **No Request Timeout Configuration**
**Problem**: Apache proxy timeout not configured
```bash
# No ProxyTimeout or ProxyPass timeout settings
```

**Recommendation**: Add to Apache vhost
```apache
<VirtualHost *:80>
  ProxyTimeout 300
  ProxyPass / fcgi://127.0.0.1:9000/app/moodle/ timeout=300
</VirtualHost>
```

---

### 9. ⚠️ **No Log Rotation for Application Logs**
**Problem**: Apache/PHP logs not rotated
```bash
# No logrotate configuration
```

**Recommendation**: Add logrotate config
```bash
cat > /etc/logrotate.d/moodle <<'EOF'
/var/log/httpd/moodle_*.log {
  daily
  rotate 7
  compress
  delaycompress
  notifempty
  create 0640 apache apache
  sharedscripts
  postrotate
    systemctl reload httpd > /dev/null 2>&1 || true
  endscript
}
EOF
```

---

### 10. ⚠️ **No Graceful Shutdown Handling**
**Problem**: ASG termination doesn't drain connections
```typescript
updatePolicy: autoscaling.UpdatePolicy.rollingUpdate({
  maxBatchSize: 1,
  minInstancesInService: 0,  // ← Allows immediate termination
  pauseTime: cdk.Duration.minutes(10),
}),
```

**Recommendation**: Add connection draining
```typescript
targetGroup.setAttribute('deregistration_delay.timeout_seconds', '300');
```

---

## Low Priority Issues

### 11. ℹ️ **No Performance Baseline**
**Problem**: No baseline metrics for comparison
- No documentation of expected CPU/memory usage
- No baseline for "normal" PHP-FPM process count

**Recommendation**: Document baseline metrics
```markdown
# Performance Baseline
- Expected PHP-FPM processes: 10-20 (under normal load)
- Expected CPU: 20-40%
- Expected Memory: 50-70%
- Expected response time: <500ms
```

---

### 12. ℹ️ **No Automated Remediation**
**Problem**: Issues detected but not automatically fixed
- High CPU detected → no automatic restart
- PHP-FPM stuck → no automatic restart

**Recommendation**: Add Lambda-based remediation
```typescript
// Trigger Lambda on alarm
// Lambda can restart services or terminate unhealthy instances
```

---

## Recommended Implementation Priority

### Phase 1: Critical (Implement Immediately)
1. ✅ Improve health checks (multi-level)
2. ✅ Configure PHP-FPM for production
3. ✅ Deploy CloudWatch agent configuration
4. ✅ Add CloudWatch alarms

### Phase 2: Important (Next Sprint)
5. ✅ Add ASG scaling policies
6. ✅ Reduce ASG grace period
7. ✅ Configure request timeouts
8. ✅ Add log rotation

### Phase 3: Nice-to-Have (Future)
9. ✅ Automated remediation
10. ✅ Performance baselines
11. ✅ Connection draining

---

## Summary

**Current State**: Infrastructure is solid but lacks operational visibility

**Key Gap**: No monitoring of PHP-FPM resource exhaustion

**Solution**: Implement comprehensive monitoring, proper PHP-FPM configuration, and automated remediation

**Expected Outcome**: Prevent PHP-FPM exhaustion issues and enable early detection of problems

