# Training Moodle Migration Checklist

Use this checklist to track progress through the migration process.

---

## Pre-Migration Preparation

### Prerequisites
- [ ] Existing MoodleCdkStack deployed and healthy
- [ ] AWS CLI configured with credentials
- [ ] Node.js and npm installed
- [ ] CDK CLI installed (`npm install -g aws-cdk`)
- [ ] Access to SFTP server verified
- [ ] SSH key file exists at `source/etraintouchstone`
- [ ] Stakeholders notified of migration timeline

### Documentation Review
- [ ] Read `TRAINING-MIGRATION-SUMMARY.md`
- [ ] Read `TRAINING-MOODLE-MIGRATION-PLAN.md`
- [ ] Read `TRAINING-DEPLOYMENT-QUICKSTART.md`
- [ ] Understand shared VPC architecture
- [ ] Review cost estimates (~$116/month)

---

## Phase 1: Planning & Preparation ✅ COMPLETE

- [x] CDK stack created (`lib/training-moodle-cdk-stack.ts`)
- [x] App updated to deploy both stacks (`bin/moodle-cdk.ts`)
- [x] Download script created (`scripts/download-training-backup.ps1`)
- [x] Restoration scripts created
- [x] Documentation completed
- [x] Architecture reviewed and approved

---

## Phase 2: Infrastructure Deployment

### Pre-Deployment
- [ ] Run `npm run build` successfully
- [ ] Verify VPC exists: `aws ec2 describe-vpcs --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack"`
- [ ] Review stack outputs from MoodleCdkStack
- [ ] Confirm AWS account and region

### Deployment
- [ ] Run: `cdk deploy TrainingMoodleCdkStack --require-approval never`
- [ ] Deployment completed successfully (20-30 minutes)
- [ ] No errors in CloudFormation console

### Post-Deployment Verification
- [ ] VPC imported successfully
- [ ] RDS database created and available
- [ ] EFS file systems created (App + Data)
- [ ] ALB created and healthy
- [ ] ASG created with 2 instances
- [ ] Security groups created
- [ ] S3 bucket created
- [ ] CloudWatch log groups created

### Capture Stack Outputs
- [ ] TrainingMoodleUrl: `_______________________________`
- [ ] TrainingDatabaseEndpoint: `_______________________________`
- [ ] TrainingDatabaseSecretArn: `_______________________________`
- [ ] TrainingAppEfsId: `_______________________________`
- [ ] TrainingDataEfsId: `_______________________________`
- [ ] TrainingScriptsBucket: `_______________________________`

---

## Phase 3: Backup Download & Preparation

### SFTP Connection
- [ ] Test SFTP connection: `sftp -i source/etraintouchstone etraintouchstone@sftp-prod2-ca-cenral-1.lambdasolutionscloud.net`
- [ ] List available files on SFTP server
- [ ] Identify database backup file
- [ ] Identify moodledata backup file
- [ ] Note file sizes and dates

### Download Backups
- [ ] Run: `pwsh scripts/download-training-backup.ps1 -UploadToS3`
- [ ] Database backup downloaded successfully
- [ ] Moodledata backup downloaded successfully
- [ ] Files uploaded to S3 bucket
- [ ] Verify S3 upload: `aws s3 ls s3://training-moodle-backups-{account}-ca-central-1/`

### Record Backup Details
- [ ] Database file: `_______________________________`
- [ ] Database size: `_______________________________`
- [ ] Moodledata file: `_______________________________`
- [ ] Moodledata size: `_______________________________`
- [ ] S3 bucket: `_______________________________`

---

## Phase 4: Database & File Restoration

### Pre-Restoration
- [ ] Get ASG name from CloudFormation
- [ ] Scale ASG to 1 instance
- [ ] Wait 30 seconds for scaling
- [ ] Identify running instance ID
- [ ] Verify instance has SSM agent running

### Database Restoration
- [ ] Run: `pwsh scripts/restore-training-complete.ps1 -DatabaseBackup "{file}" -MoodledataBackup "{file}"`
- [ ] Database restoration started
- [ ] Monitor SSM command progress
- [ ] Database restoration completed successfully
- [ ] Verify table count
- [ ] Verify user count
- [ ] Verify course count

### Moodledata Restoration
- [ ] Moodledata restoration started
- [ ] Monitor SSM command progress
- [ ] Moodledata restoration completed successfully
- [ ] Verify directory structure
- [ ] Verify file count
- [ ] Verify permissions (apache:apache)

### Moodle Code Deployment
- [ ] Verify Moodle code at `/app/moodle`
- [ ] Verify correct branch (MOODLE_500_STABLE)
- [ ] Verify ownership (apache:apache)
- [ ] Verify permissions

---

## Phase 5: Configuration & Testing

### Configuration
- [ ] Verify config.php exists at `/app/moodle/config.php`
- [ ] Verify database connection settings
- [ ] Verify wwwroot setting
- [ ] Verify dataroot setting (`/data/moodledata`)
- [ ] Verify reverse proxy settings (disabled)

### Moodle Upgrade
- [ ] Run: `php admin/cli/upgrade.php --non-interactive`
- [ ] Upgrade completed successfully
- [ ] No errors in upgrade output
- [ ] Run: `php admin/cli/purge_caches.php`
- [ ] Caches purged successfully

### Functional Testing
- [ ] Access ALB URL in browser
- [ ] Homepage loads successfully
- [ ] Login as admin works
- [ ] Browse courses
- [ ] View course content
- [ ] Test user enrollment
- [ ] Upload file
- [ ] Download file
- [ ] Test quiz functionality
- [ ] Verify plugins working
- [ ] Check theme rendering
- [ ] Test mobile view

### Performance Testing
- [ ] Page load time < 3 seconds
- [ ] Database queries performing well
- [ ] File uploads fast
- [ ] File downloads fast
- [ ] No 500 errors
- [ ] No timeout errors

### Security Testing
- [ ] File permissions correct
- [ ] Database credentials secured
- [ ] No sensitive data in logs
- [ ] Security headers present
- [ ] Health check endpoint working

---

## Phase 6: DNS Cutover & Go-Live

### Pre-Cutover
- [ ] All tests passing
- [ ] Stakeholders notified
- [ ] Rollback plan documented
- [ ] Monitoring configured
- [ ] Alerts set up

### DNS Configuration
- [ ] Get ALB DNS name
- [ ] Create DNS record: `training.tsin.ca` → ALB
- [ ] Verify DNS propagation
- [ ] Test access via `training.tsin.ca`

### Update Moodle Configuration
- [ ] Run: `pwsh scripts/fix-moodle-wwwroot.ps1 -Stack TrainingMoodleCdkStack -CustomDomain "https://training.tsin.ca"`
- [ ] Verify wwwroot updated in config.php
- [ ] Verify wwwroot updated in database
- [ ] Test redirects working correctly
- [ ] Purge caches

### Scale Up
- [ ] Scale ASG to 2 instances
- [ ] Wait for instances to be healthy
- [ ] Verify both instances in target group
- [ ] Verify both instances healthy
- [ ] Test load balancing

### SSL Certificate (Optional but Recommended)
- [ ] Request ACM certificate for `training.tsin.ca`
- [ ] Verify domain ownership
- [ ] Add HTTPS listener to ALB
- [ ] Update security group for port 443
- [ ] Redirect HTTP to HTTPS
- [ ] Update Moodle wwwroot to `https://`

---

## Post-Migration

### Monitoring (First 24 Hours)
- [ ] Monitor CloudWatch metrics
- [ ] Check error logs
- [ ] Verify user access
- [ ] Monitor performance
- [ ] Check email delivery (if configured)
- [ ] Review security logs
- [ ] Monitor RDS performance
- [ ] Monitor EFS performance
- [ ] Monitor ALB metrics

### Cleanup
- [ ] Remove temporary DNS records (if any)
- [ ] Delete local backup files (keep S3 copies)
- [ ] Remove migration lock files
- [ ] Archive migration logs
- [ ] Update documentation

### Documentation
- [ ] Document final configuration
- [ ] Document admin credentials
- [ ] Document backup procedures
- [ ] Document monitoring procedures
- [ ] Document troubleshooting steps
- [ ] Update runbooks

### Handoff
- [ ] Train administrators
- [ ] Provide access credentials
- [ ] Share documentation
- [ ] Schedule follow-up review
- [ ] Establish support procedures

---

## Success Criteria

All of the following must be true:

- ✅ Infrastructure deployed successfully
- ✅ Database restored with all data intact
- ✅ All files accessible with correct permissions
- ✅ Moodle accessible via HTTPS
- ✅ All courses and users present
- ✅ No errors in logs
- ✅ Performance meets expectations
- ✅ Email delivery working (if configured)
- ✅ Monitoring and alerts active
- ✅ DNS pointing to new infrastructure
- ✅ SSL certificate installed (recommended)
- ✅ Stakeholders satisfied

---

## Rollback Plan

If critical issues occur:

### Before DNS Cutover
- [ ] Fix issues and retry
- [ ] No impact to users

### After DNS Cutover
- [ ] Revert DNS to old server immediately
- [ ] Scale down new ASG to 0
- [ ] Investigate and fix issues
- [ ] Re-test before second cutover attempt

---

## Notes & Issues

Use this section to track any issues or notes during migration:

```
Date: ___________
Issue: ___________________________________________________________
Resolution: _______________________________________________________

Date: ___________
Issue: ___________________________________________________________
Resolution: _______________________________________________________

Date: ___________
Issue: ___________________________________________________________
Resolution: _______________________________________________________
```

---

## Sign-Off

### Migration Team

- [ ] Technical Lead: _________________ Date: _________
- [ ] System Administrator: _________________ Date: _________
- [ ] Database Administrator: _________________ Date: _________

### Stakeholders

- [ ] IT Manager: _________________ Date: _________
- [ ] Project Sponsor: _________________ Date: _________

---

## Timeline

| Phase | Planned Start | Actual Start | Planned End | Actual End | Status |
|-------|--------------|--------------|-------------|------------|--------|
| Phase 1 | | | | ✅ | Complete |
| Phase 2 | | | | | |
| Phase 3 | | | | | |
| Phase 4 | | | | | |
| Phase 5 | | | | | |
| Phase 6 | | | | | |

---

**Migration Completed**: ___________  
**Final Status**: ___________  
**Total Duration**: ___________

