# Moodle Backup & Copy Issues - Summary & Resolution

**Date:** February 7, 2026  
**Status:** ✅ PARTIALLY FIXED - Manual intervention required

---

## Problem Summary

### Issues Identified:

1. **❌ CRITICAL: No Cron Running**
   - System cron (crond) is not installed or running on either instance
   - Moodle cron has not run since September 2025
   - This prevents ALL asynchronous tasks from processing

2. **❌ Stuck Backup Controllers**
   - Multiple backup operations stuck in "pending" state
   - elearning: 4 stuck backups
   - training: 4 stuck backups

3. **❌ Large Course Sizes**
   - **Family Medicine Asynchronous Courses: 4.7 GB** (103 files)
   - **Canadian Medicine Primer Asynchronous: 4.6 GB** (34 files)
   - These are VERY large courses that will take significant time to backup

4. **⚠️ Missing Backup Directory**
   - `/data/moodledata/backup` directory did not exist
   - Now created by fix script

---

## What Was Fixed

### ✅ Actions Completed on elearning.tsin.ca:

1. ✅ Cleared stuck backup controllers (older than 1 hour)
2. ✅ Reset failed adhoc tasks
3. ✅ Enabled backup scheduled tasks
4. ✅ Created missing `/data/moodledata/backup` directory
5. ✅ Fixed dataroot permissions
6. ✅ Purged Moodle caches
7. ✅ Ran cron manually (60 seconds - processed scheduled tasks)

### Current Status:
- Backup directory now exists
- Old stuck backups cleared
- System is ready for new backup attempts
- **BUT: Cron is still not running automatically**

---

## Why Backups Get Stuck

### The Problem:
When you create a backup or copy a course in Moodle:

1. Moodle creates a "backup controller" record in the database
2. Moodle queues an "adhoc task" to perform the actual backup
3. **Cron must run to process this adhoc task**
4. Without cron, the task never executes → backup stays "pending" forever

### Why It Takes So Long:
- **4.7 GB courses** are HUGE for Moodle
- A typical course is 10-100 MB
- Backing up a 4.7 GB course could take:
  - **5-15 minutes** on a fast system
  - **30-60 minutes** on a slower system or with network storage (EFS)
  - The backup process must:
    - Copy all files from the course
    - Export database records
    - Create a compressed archive
    - Store it in the backup directory

---

## ⚠️ CRITICAL: Cron Must Be Configured

### The Root Cause:
**Cron is not installed or configured on your EC2 instances.**

Without cron:
- ❌ Backups don't process
- ❌ Course copies don't work
- ❌ Automated backups don't run
- ❌ Cleanup tasks don't run
- ❌ Email notifications may be delayed
- ❌ Many other Moodle features break

### Solution Options:

#### Option 1: Install Cron on EC2 Instances (RECOMMENDED)

Run this on BOTH instances (elearning and training):

```bash
# Install cronie package
sudo yum install cronie -y

# Start and enable cron service
sudo systemctl start crond
sudo systemctl enable crond

# Add Moodle cron for apache user (runs every minute)
echo '* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1' | sudo crontab -u apache -

# Verify it's running
sudo systemctl status crond
sudo crontab -u apache -l
```

#### Option 2: Use AWS EventBridge + Lambda

Create a Lambda function that runs every minute:
```python
import boto3

def lambda_handler(event, context):
    ssm = boto3.client('ssm')
    
    # Run on elearning
    ssm.send_command(
        InstanceIds=['i-011c65cd247389ee6'],
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': ['sudo -u apache /usr/bin/php /app/moodle/admin/cli/cron.php']}
    )
    
    # Run on training
    ssm.send_command(
        InstanceIds=['i-0527f81ac3fde0ec3'],
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': ['sudo -u apache /usr/bin/php /app/moodle/admin/cli/cron.php']}
    )
```

#### Option 3: Update CDK/User Data

Add cron installation to your EC2 user data script so it's configured automatically on new instances.

---

## Testing Instructions

### After Installing Cron:

1. **Wait 2-3 minutes** for cron to run a few times

2. **Verify cron is working:**
   ```bash
   # Check scheduled tasks are running
   sudo -u apache /usr/bin/php /app/moodle/admin/cli/scheduled_task.php --list
   ```

3. **Test a small course first:**
   - Find a small course (< 100 MB)
   - Try creating a backup
   - It should complete in 1-2 minutes

4. **Then test the large courses:**
   - Try backing up "Family Medicine Asynchronous Courses"
   - **Expect 15-30 minutes** for a 4.7 GB course
   - Monitor progress in Moodle admin interface

5. **Test course copy:**
   - Try copying a small course
   - Should complete in 2-5 minutes

---

## Monitoring Backup Progress

### Check if backup is actually running:

```bash
# Check for running PHP processes
ps aux | grep cron.php

# Check backup temp files (should be growing)
ls -lh /data/moodledata/temp/backup/

# Check database for active backups
# (Run via SSM or SSH)
```

### Check backup controller status:

```sql
SELECT 
  backupid,
  itemid as course_id,
  status,
  FROM_UNIXTIME(timecreated) as created,
  FROM_UNIXTIME(timemodified) as modified
FROM mdl_backup_controllers 
WHERE status != 1000
ORDER BY timemodified DESC;
```

**Status codes:**
- 200 = Pending
- 700 = In Progress
- 800 = Completed
- 1000 = Finished (cleaned up)

---

## Course Settings Error (Family Medicine)

### Status: ✅ NO ERROR FOUND

The diagnostic showed:
- Course ID 77 exists
- Course name: "Family Medicine Asynchronous Courses"
- All course format options are intact
- All course sections are accessible
- **No database errors detected**

The error you experienced may have been:
- A temporary issue (now resolved)
- Related to the stuck backups (now cleared)
- A caching issue (caches now purged)

**Recommendation:** Try accessing the course settings again. It should work now.

---

## Next Steps

### Immediate (Required):

1. **Install cron on both instances** (see Option 1 above)
2. **Verify cron is running** after installation
3. **Test backup on a small course** first
4. **Test course copy** functionality

### Short-term:

1. Monitor backup performance for large courses
2. Consider splitting very large courses into smaller modules
3. Set up automated monitoring for cron status

### Long-term:

1. Update CDK infrastructure code to include cron installation
2. Consider implementing backup size limits or warnings
3. Set up CloudWatch alarms for failed backups
4. Review course content - 4.7 GB is unusually large

---

## Scripts Created

All diagnostic and fix scripts are in the `scripts/` directory:

- `diagnose-backup-copy-issues.json` - Full diagnostic
- `diagnose-backup-elearning.ps1` - Run diagnostic on elearning
- `diagnose-backup-training.ps1` - Run diagnostic on training
- `fix-backup-simple.json` - Fix script
- `fix-backup-elearning.ps1` - Apply fixes to elearning
- `fix-backup-training.ps1` - Apply fixes to training
- `check-course-sizes.json` - Check course sizes and backup status

---

## Support

If issues persist after installing cron:

1. Check the full diagnostic output
2. Review Moodle error logs: `/var/log/php-fpm/error.log`
3. Check Apache logs: `/var/log/httpd/error_log`
4. Verify disk space is sufficient for large backups
5. Consider increasing PHP memory limits for large courses

