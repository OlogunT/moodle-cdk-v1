# Moodle Backup and Copy Issues - Diagnostic Report

**Date:** February 7, 2026  
**Systems:** elearning.tsin.ca and training.tsin.ca

## Executive Summary

Both Moodle instances (elearning and training) have **critical issues** preventing course backups and course copying from working properly. The main problems are:

1. **Cron is not running** - Moodle's scheduled tasks are not being executed
2. **Stuck backup controllers** - Multiple backup operations are stuck in pending state
3. **Failed adhoc tasks** - Backup and copy tasks are queued but not processing
4. **Missing backup directory** - The backup directory doesn't exist in moodledata

## Detailed Findings

### ELEARNING.TSIN.CA (MoodleCdkStack)

#### Critical Issues Found:
1. **Cron Status:** ❌ NOT RUNNING
   - `crond` service is inactive
   - No Moodle cron configured in system cron
   
2. **Stuck Backup Controllers:** ❌ 4 STUCK BACKUPS
   - Backup ID: `5d8a30deac11d3a325fee642c37b74ef` - Family Medicine Asynchronous Courses (Status: 700, Created: 2026-02-06)
   - Backup ID: `cc7a1287dd2d58931cf57525840e3461` - Canadian Medicine Primer Asynchronous (Status: 700, Created: 2026-02-03)
   - Backup ID: `dd0b188a28dbb7b36e5741b0940eac3b` - Restore operation (Status: 200, Created: 2026-01-21)
   - Backup ID: `2ce528f04807a7bd79bfeccb632eabf5` - Canadian Medicine Primer Asynchronous (Status: 700, Created: 2026-01-21)

3. **Pending Adhoc Tasks:** ❌ 6 TASKS STUCK
   - 2 asynchronous backup tasks (from Feb 6 and Feb 3)
   - 1 asynchronous copy task (from Jan 21)
   - 3 course backup tasks (from Sep 29)

4. **Missing Directories:** ⚠️ WARNING
   - `/data/moodledata/backup` directory does not exist

5. **Course Settings Error:** ✅ NO DATABASE ERROR
   - The "Family Medicine Asynchronous Courses" (ID: 77) exists and is accessible
   - Course format options are intact
   - No database corruption detected

#### Last Scheduled Task Runs:
- backup_cleanup_task: 2025-09-29 20:52:41
- automated_backup_task: 2025-09-29 20:52:39
- **Tasks haven't run since September 2025!**

---

### TRAINING.TSIN.CA (TrainingMoodleCdkStack)

#### Critical Issues Found:
1. **Cron Status:** ❌ NOT RUNNING
   - `crond` service is inactive
   - No Moodle cron configured in system cron

2. **Stuck Backup Controllers:** ❌ 4 STUCK BACKUPS
   - Backup ID: `14fe75d42a61ede1b194b75056174d01` - RNCCAP Examiner Training Tutorial 2025 (Status: 700, Created: 2026-01-02)
   - Backup ID: `34c96290a50be74d5aeb7f38c3fc9c81` - Restore operation (Status: 200, Created: 2026-01-02)
   - Backup ID: `797830fd7839950b9e86a2f425761f6e` - Restore operation (Status: 200, Created: 2025-12-22)
   - Backup ID: `f93c5678d301b2b085f4f07553d6e7cd` - RNCCAP Virtual Examiner Training Tutorial (Status: 700, Created: 2025-12-22)

3. **Pending Adhoc Tasks:** ❌ 4 COPY TASKS STUCK
   - 4 asynchronous copy tasks (from Jan 2, Dec 22, Dec 22, Nov 12)

4. **Missing Directories:** ⚠️ WARNING
   - `/data/moodledata/backup` directory does not exist

5. **Course Settings:** ℹ️ INFO
   - "Family Medicine Asyncronous Course" not found on training instance (this is expected)

#### Last Scheduled Task Runs:
- backup_cleanup_task: 2025-09-05 18:10:04
- automated_backup_task: 2025-09-05 17:50:04
- **Tasks haven't run since September 2025!**

---

## Root Cause Analysis

### Why Backups Get Stuck in "Pending"

1. **No Cron Execution:** Moodle relies on cron to process asynchronous tasks. Without cron running, backup and copy operations are queued but never executed.

2. **Backup Controllers Not Cleaned Up:** When backups fail or timeout, the backup controller records remain in the database with status codes indicating incomplete operations (700 = in progress, 200 = pending).

3. **Adhoc Task Queue Buildup:** Backup and copy operations create adhoc tasks that need cron to process them. These tasks accumulate in the queue.

### Why Course Copy Doesn't Work

Course copying in Moodle is a two-step process:
1. Create a backup of the source course (asynchronous_backup_task)
2. Restore the backup to create the new course (asynchronous_copy_task)

Without cron, neither step completes, so the copy operation appears to hang.

---

## Solution Applied

A fix script has been created and is currently running on both instances:

### Actions Taken:
1. ✅ Clear stuck backup controllers (older than 1 hour)
2. ✅ Reset failed adhoc tasks
3. ✅ Enable backup scheduled tasks
4. ✅ Create missing backup directory
5. ✅ Fix dataroot permissions
6. ✅ Purge Moodle caches
7. ✅ Run cron manually to process queued tasks

### Scripts Created:
- `scripts/diagnose-backup-copy-issues.json` - Diagnostic script
- `scripts/diagnose-backup-elearning.ps1` - Run diagnostics on elearning
- `scripts/diagnose-backup-training.ps1` - Run diagnostics on training
- `scripts/fix-backup-simple.json` - Fix script (SSM command)
- `scripts/fix-backup-elearning.ps1` - Apply fixes to elearning
- `scripts/fix-backup-training.ps1` - Apply fixes to training

---

## Long-Term Solution Required

### ⚠️ CRITICAL: Cron Must Be Configured

The instances do not have cron installed or configured. This is a **critical infrastructure issue** that must be resolved.

### Options:

#### Option 1: Install and Configure System Cron (Recommended)
```bash
# On each EC2 instance
sudo yum install cronie -y
sudo systemctl start crond
sudo systemctl enable crond

# Add Moodle cron for apache user
echo '* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1' | sudo crontab -u apache -
```

#### Option 2: Use AWS EventBridge + Lambda
Create a Lambda function that runs Moodle cron via SSM every minute.

#### Option 3: Add to User Data Script
Update the EC2 launch template to install and configure cron automatically.

---

## Testing Instructions

After the fix script completes:

### Test on elearning.tsin.ca:
1. Log in as admin
2. Navigate to a course (e.g., "Family Medicine Asynchronous Courses")
3. Go to Course Administration → More → Course reuse → Backup
4. Create a backup and verify it completes (not stuck in pending)
5. Try copying the course and verify it works

### Test on training.tsin.ca:
1. Log in as admin
2. Navigate to any course
3. Try creating a backup
4. Try copying a course

---

## Monitoring

To check if cron is working:

```bash
# Check cron status
sudo systemctl status crond

# Check last cron run
sudo -u apache /usr/bin/php /app/moodle/admin/cli/cron.php

# Check scheduled tasks in database
SELECT classname, FROM_UNIXTIME(lastruntime) as last_run 
FROM mdl_task_scheduled 
ORDER BY lastruntime DESC LIMIT 10;
```

---

## Next Steps

1. ✅ Fix scripts are running on both instances
2. ⏳ Wait for fix scripts to complete (running cron manually)
3. 🔄 Test backup and copy functionality
4. ❗ **MUST DO:** Install and configure cron on both instances
5. 📊 Verify scheduled tasks are running regularly
6. 📝 Update infrastructure code to include cron in future deployments

