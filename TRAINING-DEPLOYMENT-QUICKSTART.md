# Training Moodle Deployment Quick Start Guide

## Overview

This guide provides step-by-step instructions to deploy the training.tsin.ca Moodle instance that shares the VPC with learning.tsin.ca but has completely separate data and application resources.

---

## Prerequisites

✅ Existing `MoodleCdkStack` deployed and running (learning.tsin.ca)  
✅ AWS CLI configured with appropriate credentials  
✅ Node.js and npm installed  
✅ CDK CLI installed (`npm install -g aws-cdk`)  
✅ Access to SFTP server: `etraintouchstone@sftp-prod2-ca-cenral-1.lambdasolutionscloud.net`  
✅ SSH key file at `source/etraintouchstone`

---

## Phase 1: Download Backup Files (1-3 hours)

### Step 1: Test SFTP Connection

```powershell
# Test connection
sftp -i source/etraintouchstone etraintouchstone@sftp-prod2-ca-cenral-1.lambdasolutionscloud.net

# Once connected, list files
ls -lh

# Exit
bye
```

### Step 2: Download Backups

```powershell
# Run the download script
pwsh scripts/download-training-backup.ps1 -UploadToS3

# Follow prompts to select database and moodledata files
# Script will download and upload to S3 automatically
```

**Expected Output**:
- Database backup in `backups/training/`
- Moodledata backup in `backups/training/`
- Both uploaded to S3 bucket: `training-moodle-backups-{account}-ca-central-1`

---

## Phase 2: Deploy Infrastructure (20-30 minutes)

### Step 1: Build TypeScript

```powershell
npm run build
```

### Step 2: Verify VPC Lookup

The training stack will import the existing VPC. Verify it can be found:

```powershell
# List VPCs to confirm the learning VPC exists
aws ec2 describe-vpcs --region ca-central-1 --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack"
```

### Step 3: Deploy Training Stack

```powershell
# Deploy only the training stack
cdk deploy TrainingMoodleCdkStack --require-approval never

# Or deploy both stacks (if you want to update learning stack too)
cdk deploy --all
```

**What Gets Created**:
- ✅ Separate RDS MariaDB database
- ✅ Separate EFS file systems (App + Data)
- ✅ Separate Application Load Balancer
- ✅ Separate Auto Scaling Group (2 instances)
- ✅ Separate Security Groups
- ✅ Separate S3 bucket for scripts
- ✅ Separate CloudWatch log groups

**What Gets Shared**:
- ✅ VPC (imported from MoodleCdkStack)
- ✅ Subnets (Public, Private, Database)
- ✅ NAT Gateways
- ✅ Internet Gateway

### Step 4: Get Stack Outputs

```powershell
# Get ALB URL and other outputs
aws cloudformation describe-stacks --stack-name TrainingMoodleCdkStack --region ca-central-1 --query "Stacks[0].Outputs"
```

**Important Outputs**:
- `TrainingMoodleUrl` - ALB DNS name
- `TrainingDatabaseEndpoint` - RDS endpoint
- `TrainingDatabaseSecretArn` - Database credentials
- `TrainingAppEfsId` - App EFS ID
- `TrainingDataEfsId` - Data EFS ID

---

## Phase 3: Restore Database & Files (2-4 hours)

### Step 1: Scale Down ASG (Prevent Auto-Install)

```powershell
# Get ASG name
$asgName = aws cloudformation describe-stack-resources `
    --stack-name TrainingMoodleCdkStack `
    --region ca-central-1 `
    --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" `
    --output text

# Scale to 1 instance
aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName --desired-capacity 1 --region ca-central-1

# Wait 30 seconds
Start-Sleep -Seconds 30
```

### Step 2: Run Complete Restoration

```powershell
# Run orchestration script
pwsh scripts/restore-training-complete.ps1 `
    -DatabaseBackup "your-database-file.sql.gz" `
    -MoodledataBackup "your-moodledata-file.tar.gz"
```

This script will:
1. Upload restoration scripts to S3
2. Restore database from backup
3. Restore moodledata files from backup
4. Verify restoration

**Expected Duration**: 30-60 minutes depending on backup sizes

### Step 3: Verify Restoration

```powershell
# Get running instance
$instanceId = aws ec2 describe-instances `
    --region ca-central-1 `
    --filters "Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack" "Name=instance-state-name,Values=running" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text

# Check database
aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters 'commands=["mysql -h $DB_ENDPOINT -u $DB_USER -p$DB_PASS -e \"SELECT COUNT(*) FROM mdl_user;\" moodle"]' `
    --region ca-central-1

# Check moodledata
aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters 'commands=["ls -lh /data/moodledata", "du -sh /data/moodledata"]' `
    --region ca-central-1
```

---

## Phase 4: Deploy Moodle Code & Configure (1-2 hours)

### Step 1: Deploy Moodle Code

The bootstrap script should have already deployed Moodle code. Verify:

```powershell
aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters 'commands=["ls -la /app/moodle", "cd /app/moodle && git branch"]' `
    --region ca-central-1
```

### Step 2: Create/Update config.php

The intelligent installer should create config.php, but verify it points to the correct database:

```powershell
aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters 'commands=["grep -E \"(dbhost|wwwroot|dataroot)\" /app/moodle/config.php"]' `
    --region ca-central-1
```

### Step 3: Run Moodle Upgrade

```powershell
$upgradeCommands = @(
    "cd /app/moodle",
    "sudo -u apache php admin/cli/upgrade.php --non-interactive",
    "sudo -u apache php admin/cli/purge_caches.php"
) | ConvertTo-Json -Compress

aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=$upgradeCommands" `
    --timeout-seconds 1800 `
    --region ca-central-1
```

### Step 4: Test Access

```powershell
# Get ALB URL
$albUrl = aws cloudformation describe-stacks `
    --stack-name TrainingMoodleCdkStack `
    --region ca-central-1 `
    --query "Stacks[0].Outputs[?OutputKey=='TrainingMoodleUrl'].OutputValue" `
    --output text

Write-Host "Training Moodle URL: $albUrl"

# Test health endpoint
curl "$albUrl/health.php"

# Test Moodle homepage
curl -I "$albUrl/"
```

---

## Phase 5: Scale Up & Configure DNS (1 hour)

### Step 1: Scale ASG Back Up

```powershell
# Scale to 2 instances
aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName --desired-capacity 2 --region ca-central-1

# Wait for instances to be healthy
scripts/monitor-deployment.ps1 -Stack TrainingMoodleCdkStack
```

### Step 2: Configure DNS

**Option A: Route53 (Recommended)**

```powershell
# Get ALB DNS name
$albDns = aws elbv2 describe-load-balancers `
    --region ca-central-1 `
    --query "LoadBalancers[?contains(LoadBalancerName, 'Training')].DNSName" `
    --output text

# Create Route53 alias record
# training.tsin.ca -> ALB DNS name
```

**Option B: External DNS Provider**

Create a CNAME record:
- Name: `training.tsin.ca`
- Type: `CNAME`
- Value: `{ALB DNS name from above}`
- TTL: `300`

### Step 3: Update Moodle wwwroot

Once DNS is configured:

```powershell
pwsh scripts/fix-moodle-wwwroot.ps1 -Stack TrainingMoodleCdkStack -CustomDomain "https://training.tsin.ca"
```

---

## Phase 6: Testing & Validation (2-4 hours)

### Functional Tests

- [ ] Login as admin
- [ ] Browse courses
- [ ] Test user enrollment
- [ ] Upload/download files
- [ ] Test quiz functionality
- [ ] Verify plugins working
- [ ] Check theme rendering
- [ ] Test mobile responsiveness

### Performance Tests

- [ ] Page load time < 3 seconds
- [ ] Database query performance
- [ ] File upload/download speed
- [ ] Concurrent user handling

### Security Tests

- [ ] HTTPS enforced (after SSL certificate)
- [ ] Security headers present
- [ ] File permissions correct
- [ ] Database credentials secured

---

## Troubleshooting

### Issue: VPC Lookup Fails

```powershell
# Verify VPC exists and has correct tags
aws ec2 describe-vpcs --region ca-central-1 --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack"

# If VPC ID is known, update training-moodle-cdk-stack.ts:
# const vpc = ec2.Vpc.fromLookup(this, 'ExistingVpc', {
#   vpcId: 'vpc-xxxxxxxxx'
# });
```

### Issue: Database Restoration Fails

```powershell
# Check database connectivity
aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters 'commands=["mysql -h $DB_ENDPOINT -u $DB_USER -p$DB_PASS -e \"SELECT 1;\""]' `
    --region ca-central-1

# Check security groups
aws ec2 describe-security-groups --region ca-central-1 --filters "Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack"
```

### Issue: EFS Mount Fails

```powershell
# Check EFS mount targets
aws efs describe-mount-targets --region ca-central-1 --file-system-id $EFS_ID

# Check EFS security groups
aws efs describe-mount-target-security-groups --region ca-central-1 --mount-target-id $MT_ID
```

---

## Monitoring & Maintenance

### CloudWatch Dashboards

```powershell
# View logs
aws logs tail /aws/ec2/training-moodle --follow --region ca-central-1
```

### Health Checks

```powershell
# Check ALB target health
aws elbv2 describe-target-health `
    --target-group-arn $TARGET_GROUP_ARN `
    --region ca-central-1
```

### Backups

Set up automated backups:
- RDS automated backups (already configured - 7 days retention)
- EFS backups via AWS Backup
- Regular database dumps to S3

---

## Cost Estimate

**Monthly Costs** (approximate):

| Resource | Cost |
|----------|------|
| RDS db.t3.small (Multi-AZ) | ~$60 |
| EFS (100GB) | ~$30 |
| EC2 t3.medium × 2 | ~$60 |
| ALB | ~$20 |
| Data Transfer | ~$10 |
| **Total** | **~$180/month** |

**Savings from Shared VPC**: ~$64/month (NAT Gateways)

---

## Next Steps

1. ✅ Complete all phases above
2. Configure SSL certificate (ACM or Let's Encrypt)
3. Set up monitoring alerts
4. Configure email (SES)
5. Set up automated backups
6. Document admin procedures
7. Train users

---

## Support

For issues or questions:
- Review: `TRAINING-MOODLE-MIGRATION-PLAN.md`
- Check CloudWatch logs
- Review CDK stack: `lib/training-moodle-cdk-stack.ts`
- Contact: it@tsin.ca

