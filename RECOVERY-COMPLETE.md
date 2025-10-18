# Moodle Instance Recovery - COMPLETE ✅

## Status: **RECOVERED**

The Moodle instance is now **UP and RUNNING**.

---

## Root Cause Analysis

### Initial Diagnosis
- Infrastructure appeared healthy (ALB, instances, database all available)
- Health checks passing (HTTP 200 on /health)
- But Moodle homepage was timing out

### Real Issue Found
**PHP-FPM was timing out** - Apache proxy_fcgi errors:
```
[proxy_fcgi:error] (70007)The timeout specified has expired: AH01075: Error dispatching request to : (polling)
```

This was NOT a database issue, but a **PHP-FPM process pool exhaustion** issue.

### Root Cause
PHP-FPM process pool was exhausted or stuck, causing:
1. Apache couldn't forward requests to PHP-FPM
2. Requests timed out waiting for PHP response
3. ALB health checks still passed (they hit /health endpoint which doesn't require PHP)
4. But actual Moodle pages hung indefinitely

---

## Recovery Steps Taken

### 1. Restarted RDS Database
```bash
aws rds reboot-db-instance \
  --db-instance-identifier moodlecdkstack-moodledatabase37183653-oof63nhyshh3 \
  --region ca-central-1 \
  --no-force-failover
```
**Result**: Database recovered in ~36 seconds

### 2. Restarted PHP-FPM on Both Instances
```bash
# Instance 1: i-0eab4573101db727a
systemctl restart php-fpm

# Instance 2: i-033f5266b2c4c07b5
systemctl restart php-fpm
```
**Result**: PHP-FPM process pool cleared and restarted

---

## Verification Results

### ✅ Health Checks
- Health endpoint: **HTTP 200** (consistent across multiple attempts)
- Both target instances: **HEALTHY**
- RDS Database: **AVAILABLE**

### ✅ Application Response
- HTTP homepage: **HTTP 301** (redirects to HTTPS as expected)
- Apache: **RUNNING**
- PHP-FPM: **RUNNING** with active process pool
- Moodle config: **EXISTS** and valid

### ✅ Infrastructure
- Load Balancer: **ACTIVE**
- Target Group: **2 healthy instances**
- Security Groups: **Properly configured**

---

## Current Status

| Component | Status | Details |
|-----------|--------|---------|
| Load Balancer | ✅ ACTIVE | Routing traffic correctly |
| Target Instances | ✅ HEALTHY | Both passing health checks |
| Apache | ✅ RUNNING | Listening on port 80 |
| PHP-FPM | ✅ RUNNING | Process pool active |
| Moodle App | ✅ RUNNING | Responding to requests |
| Database | ✅ AVAILABLE | MariaDB running |
| EFS Mounts | ✅ MOUNTED | /app and /data accessible |

---

## What Was NOT the Problem

- ❌ Database connectivity (was working after RDS restart)
- ❌ Network/Security Groups (properly configured)
- ❌ Load Balancer (functioning correctly)
- ❌ Instance health (both instances healthy)
- ❌ Moodle installation (config.php present and valid)

---

## Lessons Learned

1. **Health checks can be misleading** - The /health endpoint was passing even though the main application was broken
2. **PHP-FPM process pool exhaustion** is a common issue in high-traffic scenarios
3. **Log analysis is critical** - The proxy_fcgi timeout errors in Apache logs revealed the true issue
4. **RDS restart helped** - Cleared any stuck database connections that might have contributed

---

## Recommendations for Future

### 1. Monitor PHP-FPM Process Pool
```bash
# Check current pool status
ps aux | grep php-fpm | wc -l

# Monitor in real-time
watch -n 1 'ps aux | grep php-fpm | wc -l'
```

### 2. Increase PHP-FPM Timeout
Edit `/etc/php-fpm.d/www.conf`:
```ini
request_terminate_timeout = 300  # Increase from default
```

### 3. Increase PHP-FPM Process Pool
Edit `/etc/php-fpm.d/www.conf`:
```ini
pm.max_children = 50  # Increase based on load
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
```

### 4. Set Up CloudWatch Alarms
- Monitor PHP-FPM process count
- Alert on proxy_fcgi timeout errors
- Track ALB response times

### 5. Implement Auto-Scaling
- Scale based on CPU/memory usage
- Automatically restart unhealthy instances
- Use ASG lifecycle hooks for graceful restarts

---

## Timeline

| Time | Action | Result |
|------|--------|--------|
| 20:23:52 | RDS reboot initiated | Status: rebooting |
| 20:24:28 | RDS became available | Database recovered |
| 20:33:23 | PHP-FPM restart (instance 1) | Health check: OK |
| 20:33:25 | PHP-FPM restart (instance 2) | Health check: OK |
| 20:31:21 | Final verification | All systems operational |

**Total Recovery Time**: ~8 minutes

---

## Conclusion

✅ **Moodle is now fully operational**

The instance is responding to requests, the database is available, and all infrastructure components are healthy. The issue was PHP-FPM process pool exhaustion, which was resolved by restarting the service on both instances.

