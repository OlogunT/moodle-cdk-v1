# Cron Installation Summary

**Date:** February 7, 2026  
**Issue:** Moodle backups and course copies stuck in "pending" status  
**Root Cause:** Cron not installed on EC2 instances

---

## Actions Taken

### 1. ✅ Diagnosed the Problem

**Findings:**
- Cron service (crond) was NOT running on either instance
- Moodle cron had not executed since September 2025
- Without cron, asynchronous tasks (backups, copies) never process
- Course sizes discovered:
  - **Family Medicine Asynchronous Courses: 4.7 GB** (103 files)
  - **Canadian Medicine Primer Asynchronous: 4.6 GB** (34 files)

### 2. ✅ Applied Immediate Fixes

**On elearning.tsin.ca:**
- Cleared 4 stuck backup controllers
- Reset failed adhoc tasks
- Created missing `/data/moodledata/backup` directory
- Fixed dataroot permissions
- Purged Moodle caches
- Ran cron manually (60 seconds)

**On training.tsin.ca:**
- Same fixes applied via `scripts/run-fix-training.ps1`

### 3. ✅ Updated CDK Infrastructure

**Modified:** `scripts/bootstrap-moodle.sh`

Added cron installation to the bootstrap script that runs on all new instances:

```bash
# Install and configure cron for Moodle
echo "=== Installing and configuring cron ==="
yum install -y cronie
systemctl start crond
systemctl enable crond
# Configure Moodle cron to run every minute as apache user
echo '* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1' | crontab -u apache -
echo "Cron installed and configured for Moodle"
```

**Impact:**
- Both `MoodleCdkStack` and `TrainingMoodleCdkStack` use the same bootstrap script
- All future deployments will automatically have cron configured
- Next `cdk deploy` will update the launch template with the new bootstrap script

### 4. 🔄 Installing Cron on Existing Instances

**Scripts Created:**
- `scripts/install-cron.json` - SSM command document
- `scripts/install-cron-elearning.ps1` - Install on elearning
- `scripts/install-cron-training.ps1` - Install on training

**Status:**
- ⏳ Installation in progress on both instances
- Command IDs:
  - elearning: `b9abcc36-ac01-4ad9-9b69-b4c719536262`
  - training: (in progress)

---

## What Cron Does for Moodle

Moodle requires cron to run every minute to process:

1. **Asynchronous Backups** - Course backup operations
2. **Course Copies** - Duplicate courses for editing
3. **Scheduled Tasks** - Cleanup, maintenance, automated backups
4. **Adhoc Tasks** - One-time tasks queued by users
5. **Email Notifications** - Delayed email sending
6. **Session Cleanup** - Remove old sessions
7. **Cache Purging** - Automatic cache management
8. **Grade Calculations** - Background grade processing

**Without cron, ALL of these features fail or are severely delayed.**

---

## Expected Backup Times

Given the course sizes discovered:

| Course | Size | Expected Backup Time |
|--------|------|---------------------|
| Small course (< 100 MB) | ~50 MB | 1-2 minutes |
| Medium course | ~500 MB | 3-5 minutes |
| Family Medicine | **4.7 GB** | **15-30 minutes** |
| Canadian Medicine | **4.6 GB** | **15-30 minutes** |

**Note:** 4.7 GB courses are EXTREMELY large for Moodle. Typical courses are 10-100 MB.

---

## Verification Steps

After cron installation completes, verify it's working:

### 1. Check Cron Service Status

```bash
# Via SSM or SSH
systemctl status crond
```

Expected output: `active (running)`

### 2. Check Cron Configuration

```bash
crontab -u apache -l
```

Expected output:
```
* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1
```

### 3. Check Moodle Scheduled Tasks

```bash
sudo -u apache /usr/bin/php /app/moodle/admin/cli/scheduled_task.php --list
```

Should show recent run times (within last few minutes).

### 4. Test Backup on Small Course

1. Log into Moodle as admin
2. Navigate to a small course (< 100 MB)
3. Go to: Course Administration → More → Course reuse → Backup
4. Create a backup
5. **Expected:** Completes in 1-2 minutes (not stuck in "pending")

### 5. Test Course Copy

1. Navigate to any course
2. Go to: Course Administration → More → Course reuse → Copy course
3. Fill in the copy details
4. **Expected:** Completes in 2-5 minutes

### 6. Test Large Course Backup

1. Navigate to "Family Medicine Asynchronous Courses"
2. Create a backup
3. **Expected:** Takes 15-30 minutes (this is normal for 4.7 GB)
4. Monitor progress - should not get stuck

---

## Monitoring

### Check Last Cron Run

```sql
SELECT 
  classname,
  FROM_UNIXTIME(lastruntime) as last_run,
  TIMESTAMPDIFF(MINUTE, FROM_UNIXTIME(lastruntime), NOW()) as minutes_ago
FROM mdl_task_scheduled 
ORDER BY lastruntime DESC 
LIMIT 10;
```

All tasks should have run within the last few minutes.

### Check Adhoc Task Queue

```sql
SELECT 
  COUNT(*) as pending_tasks,
  classname
FROM mdl_task_adhoc 
WHERE faildelay = 0
GROUP BY classname;
```

Should be empty or very small (tasks process quickly).

### Check Backup Controllers

```sql
SELECT 
  COUNT(*) as active_backups,
  status
FROM mdl_backup_controllers 
WHERE status != 1000
GROUP BY status;
```

Should be empty when no backups are running.

---

## Next Steps

### Immediate (After Cron Installation):

1. ✅ Wait for cron installation to complete on both instances
2. ⏳ Verify cron is running (see verification steps above)
3. ⏳ Test backup on small course
4. ⏳ Test course copy functionality
5. ⏳ Verify "Family Medicine Asynchronous Courses" settings are accessible

### Short-term:

1. Deploy updated CDK stacks to update launch templates:
   ```powershell
   cdk deploy MoodleCdkStack --profile account-483382415631
   cdk deploy TrainingMoodleCdkStack --profile account-483382415631
   ```

2. Consider course size optimization:
   - 4.7 GB is unusually large
   - Review course content for unnecessary large files
   - Consider splitting into smaller modules

### Long-term:

1. Set up CloudWatch monitoring for cron status
2. Create alarms for failed backups
3. Implement backup size warnings in Moodle
4. Document backup time expectations for users

---

## Scripts Reference

All scripts are in the `scripts/` directory:

**Diagnostic Scripts:**
- `diagnose-backup-copy-issues.json` - Full diagnostic
- `diagnose-backup-elearning.ps1` - Run diagnostic on elearning
- `diagnose-backup-training.ps1` - Run diagnostic on training
- `check-course-sizes.json` - Check course sizes

**Fix Scripts:**
- `fix-backup-simple.json` - Clear stuck backups and tasks
- `fix-backup-elearning.ps1` - Apply fixes to elearning
- `fix-backup-training.ps1` - Apply fixes to training

**Cron Installation:**
- `install-cron.json` - SSM command document
- `install-cron-elearning.ps1` - Install on elearning
- `install-cron-training.ps1` - Install on training
- `check-cron-status.ps1` - Verify cron installation

**Bootstrap:**
- `bootstrap-moodle.sh` - Main bootstrap script (now includes cron)

---

## Documentation

- **BACKUP-ISSUES-SUMMARY.md** - Detailed explanation of issues and solutions
- **BACKUP-COPY-ISSUES-REPORT.md** - Full diagnostic findings
- **CRON-INSTALLATION-SUMMARY.md** - This document

---

## Support

If issues persist after cron installation:

1. Check Moodle error logs: `/var/log/php-fpm/error.log`
2. Check Apache logs: `/var/log/httpd/error_log`
3. Check user-data logs: `/var/log/user-data.log`
4. Check bootstrap logs: `/var/log/bootstrap-moodle.log`
5. Verify disk space: `df -h`
6. Check memory: `free -h`
7. Review PHP memory limits for large courses

