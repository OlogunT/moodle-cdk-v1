# Moodle Instance Diagnostic Findings

## Current Status: **PARTIALLY WORKING**

### ✅ What's Working
- **Load Balancer**: Active and routing traffic
- **Target Instances**: Both healthy (HTTP 200 on /health endpoint)
- **Apache Web Server**: Running and responding (HTTP 200)
- **PHP-FPM**: Running (14 PHP processes active)
- **Moodle Installation**: config.php exists and is installed
- **Database**: MariaDB available and running
- **Instance Health**: Both instances passing ALB health checks

### ❌ What's Not Working
- **Moodle Application**: Hanging/timing out when accessed
- **HTTP Requests**: Timing out when trying to access Moodle homepage
- **Database Connections**: RDS logs show "Aborted connection" errors with message "Got an error reading communication packets"

## Root Cause Analysis

The issue is **database connectivity failure**. The RDS error logs show:
```
2025-10-17 18:02:47 296464 [Warning] Aborted connection 296464 to db: 'moodle' user: 'moodleuser' host: '10.0.2.108' (Got an error reading communication packets)
```

This indicates:
1. Moodle is trying to connect to the database
2. The connection is being established
3. But then the connection is being aborted mid-communication
4. This causes PHP to hang waiting for database responses
5. Which causes HTTP requests to timeout

## Possible Causes

1. **Network/Security Group Issue**: Database security group may not allow proper communication
2. **Database Credentials**: Credentials in config.php may be incorrect or expired
3. **Database Connection Pool**: Too many connections or connection timeout issues
4. **Network Latency**: High latency causing timeouts
5. **Database Performance**: Database under heavy load or unresponsive

## Recovery Steps

### Step 1: Verify Database Connectivity
```bash
# From instance, test database connection
mysql -h <db-endpoint> -u moodleuser -p<password> -D moodle -e "SELECT 1;"
```

### Step 2: Check Security Groups
- Verify RDS security group allows inbound on port 3306 from Moodle instances
- Verify Moodle instance security group allows outbound on port 3306 to RDS

### Step 3: Restart Database
- Restart the RDS instance to clear any stuck connections
- Monitor for connection recovery

### Step 4: Restart Moodle Services
- Restart PHP-FPM: `systemctl restart php-fpm`
- Restart Apache: `systemctl restart httpd`

### Step 5: Monitor Logs
- Watch RDS error logs for connection patterns
- Check Apache error logs for PHP errors
- Check Moodle error logs in `/var/log/httpd/moodle_error.log`

## Recommended Action

**Run the Apache fix script** which will:
1. Reinstall Apache and PHP packages
2. Restart services
3. Verify health endpoints

Then **restart the RDS instance** to clear stuck connections.

If that doesn't work, **rotate the ASG** to get fresh instances with clean database connections.

