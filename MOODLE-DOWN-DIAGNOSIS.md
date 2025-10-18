# Moodle Instance Down - Diagnosis & Recovery

## Executive Summary

**Status**: Moodle is DOWN due to **database connectivity failure**

**Severity**: HIGH - Application is hanging on database queries

**Root Cause**: RDS is aborting connections with "Got an error reading communication packets"

---

## Diagnostic Results

### Infrastructure Status ✅
- Load Balancer: **ACTIVE**
- Target Instances (2): **HEALTHY** (passing health checks)
- Apache: **RUNNING** (HTTP 200 on /health)
- PHP-FPM: **RUNNING** (14 processes)
- Moodle Installation: **INSTALLED** (config.php exists)
- Database: **AVAILABLE** (MariaDB running)

### Application Status ❌
- Moodle Homepage: **TIMEOUT** (hangs indefinitely)
- Database Connections: **FAILING** (aborted by RDS)
- HTTP Requests: **TIMEOUT** (waiting for DB responses)

### Error Evidence
From RDS error logs:
```
2025-10-17 18:02:47 296464 [Warning] Aborted connection 296464 to db: 'moodle' 
user: 'moodleuser' host: '10.0.2.108' (Got an error reading communication packets)
```

---

## Why It's Happening

1. **Moodle tries to load** → Apache/PHP starts processing request
2. **PHP connects to database** → Connection established successfully
3. **Database aborts connection** → "Got an error reading communication packets"
4. **PHP hangs waiting** → Waiting for database response that never comes
5. **HTTP request times out** → Client gets timeout after 10+ seconds

---

## Recovery Plan

### Option 1: Restart RDS (Recommended First Step)
```bash
aws rds reboot-db-instance \
  --db-instance-identifier moodlecdkstack-moodledatabase37183653-oof63nhyshh3 \
  --region ca-central-1
```
**Expected**: Clears stuck connections, restores normal operation
**Time**: 2-5 minutes

### Option 2: Rotate ASG (If Option 1 Fails)
```bash
./scripts/rotate-asg.ps1
```
**Expected**: Replaces instances with fresh ones, new DB connections
**Time**: 10-15 minutes

### Option 3: Full Redeploy (Last Resort)
```bash
cdk deploy --require-approval never
```
**Expected**: Recreates entire stack with fresh resources
**Time**: 20-30 minutes

---

## Immediate Actions

### 1. Restart RDS Database
```bash
aws rds reboot-db-instance \
  --db-instance-identifier moodlecdkstack-moodledatabase37183653-oof63nhyshh3 \
  --region ca-central-1 \
  --no-force-failover
```

### 2. Monitor Recovery
```bash
# Watch RDS status
aws rds describe-db-instances \
  --db-instance-identifier moodlecdkstack-moodledatabase37183653-oof63nhyshh3 \
  --query "DBInstances[0].DBInstanceStatus" \
  --output text

# Test Moodle after RDS is available
curl -v http://Moodle-Moodl-JabjSDOCuhdn-677156032.ca-central-1.elb.amazonaws.com/health
```

### 3. If Still Down, Rotate ASG
```bash
./scripts/rotate-asg.ps1
```

---

## Verification

Once recovered, verify with:
```bash
# Health check
curl http://Moodle-Moodl-JabjSDOCuhdn-677156032.ca-central-1.elb.amazonaws.com/health

# Homepage
curl http://Moodle-Moodl-JabjSDOCuhdn-677156032.ca-central-1.elb.amazonaws.com/

# Check logs
aws logs tail /aws/ec2/moodle --follow --since 10m
```

---

## Files Generated

- `DIAGNOSTIC-FINDINGS.md` - Detailed technical findings
- `SCRIPTS-REVIEW.md` - Available recovery scripts
- `quick-diag.sh` - Quick diagnostic script (uploaded to S3)

---

## Next Steps

1. **Execute RDS restart** (recommended)
2. **Wait 5 minutes** for recovery
3. **Test Moodle** via load balancer URL
4. **If still down**, run `./scripts/rotate-asg.ps1`
5. **Monitor logs** for any errors

**Estimated Recovery Time**: 5-15 minutes

