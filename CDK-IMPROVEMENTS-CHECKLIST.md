# CDK Improvements Checklist

## Phase 1: Critical (Prevent PHP-FPM Exhaustion)

### Health Checks
- [ ] Update health check interval from 15s to 10s
- [ ] Reduce unhealthy threshold from 3 to 2
- [ ] Create `/app/moodle/health.php` that tests PHP-FPM responsiveness
- [ ] Add database connectivity test to health endpoint
- [ ] Test health endpoint returns 503 when PHP-FPM is stuck

### PHP-FPM Configuration
- [ ] Create `scripts/php-fpm-config.sh`
- [ ] Set `pm.max_children = 50` (from default ~5)
- [ ] Set `pm.start_servers = 10`
- [ ] Set `pm.min_spare_servers = 5`
- [ ] Set `pm.max_spare_servers = 20`
- [ ] Set `request_terminate_timeout = 300`
- [ ] Create `/var/log/php-fpm/` directory
- [ ] Add script to user data
- [ ] Test PHP-FPM starts with new config

### CloudWatch Agent
- [ ] Create `scripts/cloudwatch-config.json`
- [ ] Configure CPU metrics collection
- [ ] Configure memory metrics collection
- [ ] Configure PHP-FPM process count metrics
- [ ] Configure Apache error log collection
- [ ] Configure Moodle error log collection
- [ ] Configure PHP-FPM slow log collection
- [ ] Add agent startup to user data
- [ ] Verify metrics appear in CloudWatch console

### CloudWatch Alarms
- [ ] Add CPU utilization alarm (threshold: 80%)
- [ ] Add memory usage alarm (threshold: 85%)
- [ ] Add PHP-FPM process count alarm (threshold: 40)
- [ ] Add unhealthy target alarm
- [ ] Add proxy_fcgi timeout error alarm
- [ ] Test alarms trigger correctly
- [ ] Configure SNS notifications for alarms

---

## Phase 2: Important (Improve Resilience)

### Auto Scaling Policies
- [ ] Add CPU-based scaling policy (target: 70%)
- [ ] Add request-based scaling policy (target: 1000 req/min)
- [ ] Set cooldown period to 5 minutes
- [ ] Test scaling up under load
- [ ] Test scaling down when load decreases

### ASG Grace Period
- [ ] Reduce grace period from 45 minutes to 10 minutes
- [ ] Test new instances become healthy faster
- [ ] Verify health checks work during grace period

### Connection Draining
- [ ] Set deregistration delay to 300 seconds
- [ ] Enable connection termination
- [ ] Test graceful shutdown during updates

### Request Timeouts
- [ ] Add ProxyTimeout to Apache vhost
- [ ] Set timeout to 300 seconds
- [ ] Test timeout handling

### Log Rotation
- [ ] Create `/etc/logrotate.d/moodle`
- [ ] Configure daily rotation
- [ ] Keep 7 days of logs
- [ ] Test log rotation works

---

## Phase 3: Nice-to-Have (Observability)

### Log-Based Alarms
- [ ] Create metric filter for proxy_fcgi errors
- [ ] Create alarm on error count
- [ ] Create metric filter for PHP errors
- [ ] Create alarm on PHP error count

### Performance Baselines
- [ ] Document expected CPU usage
- [ ] Document expected memory usage
- [ ] Document expected PHP-FPM process count
- [ ] Document expected response times
- [ ] Create runbook for high CPU scenarios

### Automated Remediation
- [ ] Create Lambda function for service restart
- [ ] Trigger Lambda on alarm
- [ ] Test automatic restart works
- [ ] Add logging to Lambda function

### Dashboard
- [ ] Create CloudWatch dashboard
- [ ] Add CPU metric widget
- [ ] Add memory metric widget
- [ ] Add PHP-FPM process count widget
- [ ] Add request count widget
- [ ] Add error rate widget
- [ ] Add response time widget

---

## Testing Checklist

### Unit Tests
- [ ] Health check returns 200 when healthy
- [ ] Health check returns 503 when PHP-FPM stuck
- [ ] PHP-FPM config applied correctly
- [ ] CloudWatch agent starts successfully

### Integration Tests
- [ ] Deploy stack successfully
- [ ] Alarms created in CloudWatch
- [ ] Metrics appear in CloudWatch
- [ ] Logs appear in CloudWatch Logs
- [ ] Health checks pass

### Load Tests
- [ ] Run 1000 requests with 50 concurrent
- [ ] Monitor CPU stays below 80%
- [ ] Monitor memory stays below 85%
- [ ] Monitor PHP-FPM processes stay below 40
- [ ] No timeout errors in logs
- [ ] Response times acceptable

### Failure Tests
- [ ] Kill PHP-FPM process
- [ ] Verify health check fails
- [ ] Verify instance marked unhealthy
- [ ] Verify new instance launched
- [ ] Verify alarm triggered

### Scaling Tests
- [ ] Generate high CPU load
- [ ] Verify new instance launches
- [ ] Verify load distributed
- [ ] Verify CPU returns to normal
- [ ] Verify instance scales down

---

## Deployment Checklist

### Pre-Deployment
- [ ] All code reviewed
- [ ] All tests passing
- [ ] Documentation updated
- [ ] Runbooks created
- [ ] Team notified

### Deployment
- [ ] Backup current stack
- [ ] Deploy to dev environment first
- [ ] Run full test suite
- [ ] Deploy to staging
- [ ] Run load tests
- [ ] Deploy to production
- [ ] Monitor for 24 hours

### Post-Deployment
- [ ] Verify all alarms working
- [ ] Verify metrics collecting
- [ ] Verify logs centralized
- [ ] Verify scaling policies working
- [ ] Document any issues
- [ ] Update runbooks

---

## Monitoring Checklist (Ongoing)

### Daily
- [ ] Check CloudWatch dashboard
- [ ] Review alarm history
- [ ] Check error logs
- [ ] Verify no timeout errors

### Weekly
- [ ] Review performance trends
- [ ] Check scaling events
- [ ] Review cost metrics
- [ ] Update baselines if needed

### Monthly
- [ ] Full system review
- [ ] Capacity planning
- [ ] Update documentation
- [ ] Plan improvements

---

## Success Criteria

✅ **PHP-FPM exhaustion prevented**
- No more proxy_fcgi timeout errors
- PHP-FPM process count stays healthy
- Health checks detect issues early

✅ **Operational visibility improved**
- All metrics visible in CloudWatch
- All logs centralized
- Alarms trigger on issues

✅ **Resilience improved**
- Auto-scaling handles load spikes
- Graceful shutdown works
- Automatic remediation possible

✅ **Team confidence increased**
- Clear visibility into system health
- Early warning of problems
- Faster incident response

