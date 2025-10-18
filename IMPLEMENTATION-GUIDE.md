# Implementation Guide: CDK Improvements

## Phase 1: Critical Fixes (Implement First)

### 1. Improve Health Checks

**File**: `lib/moodle-cdk-stack.ts` (around line 504)

**Current**:
```typescript
healthCheck: {
  enabled: true,
  healthyHttpCodes: '200',
  path: '/health',
  interval: cdk.Duration.seconds(15),
  timeout: cdk.Duration.seconds(6),
  healthyThresholdCount: 2,
  unhealthyThresholdCount: 3,
}
```

**Improved**:
```typescript
healthCheck: {
  enabled: true,
  healthyHttpCodes: '200',
  path: '/health',
  interval: cdk.Duration.seconds(10),  // More frequent checks
  timeout: cdk.Duration.seconds(5),
  healthyThresholdCount: 2,
  unhealthyThresholdCount: 2,  // Faster detection
}
```

**Add health endpoint that tests PHP-FPM**:
```bash
# In user data, create /app/moodle/health.php
cat > /app/moodle/health.php <<'EOF'
<?php
// Test PHP-FPM is responsive
$start = microtime(true);
$db_ok = true;

// Quick DB test
try {
  $pdo = new PDO('mysql:host=' . getenv('DB_HOST'), getenv('DB_USER'), getenv('DB_PASS'));
  $pdo = null;
} catch (Exception $e) {
  $db_ok = false;
}

$elapsed = microtime(true) - $start;

if ($db_ok && $elapsed < 5) {
  http_response_code(200);
  echo "OK";
} else {
  http_response_code(503);
  echo "UNHEALTHY";
}
?>
EOF
```

---

### 2. Configure PHP-FPM for Production

**File**: Create new file `scripts/php-fpm-config.sh`

```bash
#!/bin/bash
set -e

# Configure PHP-FPM for production load
cat > /etc/php-fpm.d/www.conf <<'EOF'
[www]
user = apache
group = apache

; Process pool management
pm = dynamic
pm.max_children = 50          ; Max processes
pm.start_servers = 10         ; Start with 10
pm.min_spare_servers = 5      ; Keep at least 5 idle
pm.max_spare_servers = 20     ; Keep max 20 idle
pm.max_requests = 1000        ; Restart after 1000 requests
pm.max_requests_grace_period = 30s

; Timeouts
request_terminate_timeout = 300
request_slowlog_timeout = 10s

; Logging
slowlog = /var/log/php-fpm/www-slow.log
catch_workers_output = yes

; Status monitoring
pm.status_path = /php-fpm-status
ping.path = /php-fpm-ping
ping.response = pong
EOF

# Create log directory
mkdir -p /var/log/php-fpm
chown apache:apache /var/log/php-fpm

# Restart PHP-FPM
systemctl restart php-fpm
```

**Add to user data**:
```bash
# After PHP installation
bash /tmp/php-fpm-config.sh
```

---

### 3. Deploy CloudWatch Agent Configuration

**File**: Create `scripts/cloudwatch-config.json`

```json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/httpd/error_log",
            "log_group_name": "/aws/ec2/moodle",
            "log_stream_name": "{instance_id}/apache-error"
          },
          {
            "file_path": "/var/log/httpd/moodle_error.log",
            "log_group_name": "/aws/ec2/moodle",
            "log_stream_name": "{instance_id}/moodle-error"
          },
          {
            "file_path": "/var/log/php-fpm/www-slow.log",
            "log_group_name": "/aws/ec2/moodle",
            "log_stream_name": "{instance_id}/php-fpm-slow"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "Moodle",
    "metrics_collected": {
      "cpu": {
        "measurement": [
          {"name": "cpu_usage_idle", "rename": "CPU_IDLE", "unit": "Percent"},
          {"name": "cpu_usage_user", "rename": "CPU_USER", "unit": "Percent"}
        ],
        "metrics_collection_interval": 60,
        "totalcpu": false
      },
      "mem": {
        "measurement": [
          {"name": "mem_used_percent", "rename": "MEM_USED", "unit": "Percent"}
        ],
        "metrics_collection_interval": 60
      },
      "processes": {
        "measurement": [
          {"name": "running", "rename": "PROCESSES_RUNNING", "unit": "Count"}
        ],
        "metrics_collection_interval": 60,
        "pattern": "php-fpm"
      }
    }
  }
}
```

**Add to user data**:
```bash
# Deploy CloudWatch agent config
aws s3 cp s3://moodle-scripts-${ACCOUNT}-${REGION}/cloudwatch-config.json /opt/aws/amazon-cloudwatch-agent/etc/config.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json
```

---

### 4. Add CloudWatch Alarms

**File**: `lib/moodle-cdk-stack.ts` (add after ASG creation)

```typescript
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';

// CPU Alarm
new cloudwatch.Alarm(this, 'HighCpuAlarm', {
  metric: new cloudwatch.Metric({
    namespace: 'AWS/EC2',
    metricName: 'CPUUtilization',
    statistic: 'Average',
    period: cdk.Duration.minutes(5),
    dimensions: {
      AutoScalingGroupName: autoScalingGroup.autoScalingGroupName,
    },
  }),
  threshold: 80,
  evaluationPeriods: 2,
  alarmDescription: 'Alert when CPU > 80% for 10 minutes',
  alarmName: 'Moodle-HighCPU',
});

// Memory Alarm
new cloudwatch.Alarm(this, 'HighMemoryAlarm', {
  metric: new cloudwatch.Metric({
    namespace: 'Moodle',
    metricName: 'MEM_USED',
    statistic: 'Average',
    period: cdk.Duration.minutes(5),
  }),
  threshold: 85,
  evaluationPeriods: 2,
  alarmDescription: 'Alert when memory > 85%',
  alarmName: 'Moodle-HighMemory',
});

// PHP-FPM Process Count Alarm
new cloudwatch.Alarm(this, 'HighPhpFpmProcessAlarm', {
  metric: new cloudwatch.Metric({
    namespace: 'Moodle',
    metricName: 'PROCESSES_RUNNING',
    statistic: 'Average',
    period: cdk.Duration.minutes(5),
  }),
  threshold: 40,  // Alert if approaching max (50)
  evaluationPeriods: 2,
  alarmDescription: 'Alert when PHP-FPM processes > 40',
  alarmName: 'Moodle-HighPhpFpmProcesses',
});

// Target Unhealthy Alarm
new cloudwatch.Alarm(this, 'UnhealthyTargetsAlarm', {
  metric: targetGroup.metricUnhealthyHostCount(),
  threshold: 1,
  evaluationPeriods: 1,
  alarmDescription: 'Alert when any target becomes unhealthy',
  alarmName: 'Moodle-UnhealthyTargets',
});
```

---

## Phase 2: Important Fixes

### 5. Add ASG Scaling Policies

**File**: `lib/moodle-cdk-stack.ts` (after ASG creation)

```typescript
// Scale up on high CPU
autoScalingGroup.scaleOnCpuUtilization('CpuScaling', {
  targetUtilizationPercent: 70,
  cooldown: cdk.Duration.minutes(5),
});

// Scale up on high request count
autoScalingGroup.scaleOnRequestCount('RequestScaling', {
  targetRequestsPerMinute: 1000,
  cooldown: cdk.Duration.minutes(5),
});
```

---

### 6. Reduce ASG Grace Period

**File**: `lib/moodle-cdk-stack.ts` (line 627)

```typescript
// Before
healthCheck: autoscaling.HealthCheck.elb({
  grace: cdk.Duration.minutes(45),
}),

// After
healthCheck: autoscaling.HealthCheck.elb({
  grace: cdk.Duration.minutes(10),  // Reduced from 45
}),
```

---

### 7. Add Connection Draining

**File**: `lib/moodle-cdk-stack.ts` (after target group creation)

```typescript
targetGroup.setAttribute('deregistration_delay.timeout_seconds', '300');
targetGroup.setAttribute('deregistration_delay.connection_termination.enabled', 'true');
```

---

## Phase 3: Monitoring & Observability

### 8. Add Log-Based Alarms

```typescript
// Alert on PHP-FPM timeout errors
new logs.MetricFilter(this, 'PhpFpmTimeoutFilter', {
  logGroup: moodleLogGroup,
  metricNamespace: 'Moodle',
  metricName: 'PhpFpmTimeouts',
  filterPattern: logs.FilterPattern.literal('[...] [proxy_fcgi:error] (70007)The timeout specified has expired'),
  metricValue: '1',
});

new cloudwatch.Alarm(this, 'PhpFpmTimeoutAlarm', {
  metric: new cloudwatch.Metric({
    namespace: 'Moodle',
    metricName: 'PhpFpmTimeouts',
    statistic: 'Sum',
    period: cdk.Duration.minutes(5),
  }),
  threshold: 5,
  evaluationPeriods: 1,
  alarmDescription: 'Alert on PHP-FPM timeout errors',
});
```

---

## Testing the Improvements

### Load Test
```bash
# Install Apache Bench
yum install -y httpd-tools

# Run load test
ab -n 1000 -c 50 http://moodle-url/
```

### Monitor Metrics
```bash
# Watch PHP-FPM processes
watch -n 1 'ps aux | grep php-fpm | wc -l'

# Watch CloudWatch metrics
aws cloudwatch get-metric-statistics \
  --namespace Moodle \
  --metric-name PROCESSES_RUNNING \
  --start-time 2025-10-17T00:00:00Z \
  --end-time 2025-10-17T23:59:59Z \
  --period 60 \
  --statistics Average
```

---

## Deployment Steps

1. Update `lib/moodle-cdk-stack.ts` with improvements
2. Create new script files in `scripts/`
3. Deploy: `cdk deploy --require-approval never`
4. Verify alarms in CloudWatch console
5. Run load tests to validate
6. Monitor for 24 hours

