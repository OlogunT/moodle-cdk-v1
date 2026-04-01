# Training.tsin.ca Moodle Migration Plan

## Executive Summary

This document outlines the comprehensive migration plan for **training.tsin.ca** Moodle instance, following the proven methodology used for the successful **learning.tsin.ca** migration. This will be a **completely separate implementation** with no impact on the existing production Moodle instance.

### Migration Details
- **Source**: Lambda Solutions Cloud SFTP Server
- **SFTP Host**: `sftp-prod2-ca-cenral-1.lambdasolutionscloud.net`
- **SFTP Username**: `etraintouchstone`
- **SSH Key Location**: `source/etraintouchstone`
- **Target Domain**: `training.tsin.ca`
- **AWS Region**: `ca-central-1`
- **Stack Name**: `TrainingMoodleCdkStack` (separate from MoodleCdkStack)

### Architecture Overview

**Shared Resources** (with learning.tsin.ca):
- ✅ VPC (same VPC, subnets, NAT Gateways, Internet Gateway)
- ✅ Network infrastructure and routing

**Separate Resources** (isolated for training.tsin.ca):
- ✅ RDS MariaDB Database (completely separate)
- ✅ EFS File Systems (App + Data)
- ✅ Application Load Balancer
- ✅ Auto Scaling Group
- ✅ Security Groups
- ✅ S3 Buckets
- ✅ CloudWatch Logs
- ✅ Secrets Manager

This architecture **reduces costs** by sharing the VPC while maintaining **complete data isolation** between the two Moodle instances.

---

## Phase 1: Pre-Migration Planning & Preparation

### 1.1 Create Separate CDK Stack Configuration

**Objective**: Create a new, isolated CDK stack for training.tsin.ca that shares VPC with learning.tsin.ca

**Tasks**:
- [x] Create new stack class `TrainingMoodleCdkStack` in `lib/training-moodle-cdk-stack.ts`
- [x] Update `bin/moodle-cdk.ts` to instantiate both stacks
- [x] Configure VPC lookup to import existing VPC from MoodleCdkStack
- [x] Configure separate resource naming to avoid conflicts
- [x] Use separate tags: `Project: Training-Moodle-CDK`, `Environment: Production`

**Key Architecture - VPC Sharing**:
```typescript
// Import existing VPC from Learning Moodle Stack
const vpc = ec2.Vpc.fromLookup(this, 'ExistingVpc', {
  tags: {
    'aws:cloudformation:stack-name': 'MoodleCdkStack'
  }
});

// All other resources are separate
new TrainingMoodleCdkStack(app, 'TrainingMoodleCdkStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'ca-central-1',
  },
  description: 'Training Moodle deployment (shares VPC with Learning)',
  tags: {
    Project: 'Training-Moodle-CDK',
    Environment: 'Production',
    Owner: 'Touchstone Institute',
    Instance: 'Training'
  }
});
```

**Resource Naming Convention**:
- VPC: **Shared** (imported from MoodleCdkStack)
- RDS: `TrainingMoodleDatabase`
- EFS: `TrainingMoodleAppEfs`, `TrainingMoodleDataEfs`
- ALB: `TrainingMoodleAlb`
- ASG: `TrainingMoodleAutoScalingGroup`
- Security Groups: `TrainingAlbSecurityGroup`, `TrainingMoodleSecurityGroup`, etc.
- S3 Bucket: `training-moodle-scripts-{account}-{region}`

### 1.2 Verify SFTP Access

**Objective**: Confirm connectivity to Lambda Solutions SFTP server

**Tasks**:
- [ ] Test SSH key authentication
- [ ] List available backup files
- [ ] Identify latest backup set (database + moodledata)
- [ ] Document backup file sizes and dates

**Test Command**:
```powershell
# Test SFTP connection
sftp -i source/etraintouchstone etraintouchstone@sftp-prod2-ca-cenral-1.lambdasolutionscloud.net
```

### 1.3 Create SFTP Download Scripts

**Objective**: Automate backup file download from SFTP server

**Scripts to Create**:
1. `scripts/download-training-backup.ps1` - PowerShell script for Windows
2. `scripts/download-training-backup.sh` - Bash script for Linux/WSL

**Features**:
- Automated SFTP connection using key file
- Download database dump (SQL file)
- Download moodledata archive (tar.gz or zip)
- Verify file integrity (checksums if available)
- Store in `backups/training/` directory

### 1.4 Prepare Backup Storage

**Objective**: Create local and S3 storage for backup files

**Tasks**:
- [ ] Create local directory: `backups/training/`
- [ ] Create S3 bucket: `training-moodle-backups-{account}-ca-central-1`
- [ ] Set up lifecycle policies for backup retention
- [ ] Enable versioning and encryption

---

## Phase 2: Infrastructure Deployment

### 2.1 Deploy Training Moodle Stack

**Objective**: Deploy complete AWS infrastructure for training.tsin.ca

**Deployment Steps**:
```powershell
# Build TypeScript
npm run build

# IMPORTANT: VPC lookup requires AWS credentials and will query your account
# Make sure you're authenticated to AWS before running cdk deploy

# Deploy training stack only (will import existing VPC)
cdk deploy TrainingMoodleCdkStack --require-approval never

# Monitor deployment
scripts/monitor-deployment.ps1 -Stack TrainingMoodleCdkStack
```

**Infrastructure Components**:
- ✅ **VPC** - Imported from existing MoodleCdkStack (shared)
- ✅ **Subnets** - Uses existing Public, Private, Database subnets (shared)
- ✅ **NAT Gateways** - Uses existing NAT Gateways (shared, cost savings!)
- ✅ RDS MariaDB 10.11 (Multi-AZ for production) - **Separate**
- ✅ 2x EFS File Systems (App + Data) - **Separate**
- ✅ Application Load Balancer - **Separate**
- ✅ Auto Scaling Group (2-4 instances) - **Separate**
- ✅ CloudWatch Logs and Monitoring - **Separate**
- ✅ Security Groups and IAM Roles - **Separate**
- ✅ S3 Bucket for scripts - **Separate**
- ✅ Secrets Manager for DB credentials - **Separate**

**Expected Deployment Time**: 20-30 minutes (faster than creating new VPC)

**Cost Savings**: By sharing the VPC, you save on:
- NAT Gateway costs (~$32/month per NAT Gateway × 2 = $64/month saved)
- VPC endpoints (if any)
- Data transfer within the same VPC is free

### 2.2 Verify Infrastructure

**Objective**: Confirm all resources are healthy

**Verification Checklist**:
- [ ] VPC and subnets created
- [ ] RDS instance available and accessible
- [ ] EFS file systems mounted on EC2 instances
- [ ] ALB health checks passing
- [ ] Auto Scaling Group has 2 healthy instances
- [ ] CloudWatch logs receiving data
- [ ] S3 bucket accessible

**Verification Commands**:
```powershell
# Check stack status
aws cloudformation describe-stacks --stack-name TrainingMoodleCdkStack --region ca-central-1

# Check RDS status
aws rds describe-db-instances --region ca-central-1 --query "DBInstances[?contains(DBInstanceIdentifier, 'training')]"

# Check EC2 instances
aws ec2 describe-instances --region ca-central-1 --filters "Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack" "Name=instance-state-name,Values=running"
```

### 2.3 Configure DNS (Temporary)

**Objective**: Set up temporary ALB URL for testing

**Tasks**:
- [ ] Get ALB DNS name from CloudFormation outputs
- [ ] Create Route53 CNAME: `training-temp.tsin.ca` → ALB DNS
- [ ] Verify DNS resolution
- [ ] Test HTTPS certificate (if using ACM)

---

## Phase 3: Backup Download & Preparation

### 3.1 Download Backup Files from SFTP

**Objective**: Download latest backup files from Lambda Solutions

**Download Script** (`scripts/download-training-backup.ps1`):
```powershell
# Download database and files
$sftpHost = "sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
$sftpUser = "etraintouchstone"
$keyFile = "source/etraintouchstone"
$backupDir = "backups/training"

# Create backup directory
New-Item -ItemType Directory -Force -Path $backupDir

# Download using SFTP (requires psftp or WinSCP)
# Database backup
psftp -i $keyFile ${sftpUser}@${sftpHost} -b download-commands.txt

# Or use WinSCP for GUI download
```

**Expected Files**:
- Database dump: `training_moodle_db_YYYYMMDD.sql` or `.sql.gz`
- Moodledata: `training_moodledata_YYYYMMDD.tar.gz`
- Config backup: `config.php` (if available)

### 3.2 Upload Backups to S3

**Objective**: Store backups in S3 for EC2 instance access

**Upload Commands**:
```powershell
# Upload to S3
$bucketName = "training-moodle-backups-$(aws sts get-caller-identity --query Account --output text)-ca-central-1"

aws s3 cp backups/training/training_moodle_db.sql.gz s3://$bucketName/database/ --region ca-central-1
aws s3 cp backups/training/training_moodledata.tar.gz s3://$bucketName/moodledata/ --region ca-central-1
```

### 3.3 Prepare Restoration Scripts

**Objective**: Create scripts to restore database and files on EC2

**Scripts to Create**:
1. `scripts/restore-training-database.sh` - Database restoration
2. `scripts/restore-training-moodledata.sh` - File restoration
3. `scripts/restore-training-complete.ps1` - Orchestration script

---

## Phase 4: Database & File Restoration

### 4.1 Stop Moodle Installation (Prevent Auto-Install)

**Objective**: Prevent automatic fresh installation

**Tasks**:
- [ ] Create lock file on EFS: `/app/moodle/.migration-in-progress`
- [ ] Temporarily disable bootstrap script auto-install
- [ ] Scale ASG to 0 instances during restoration

**Commands**:
```powershell
# Scale down ASG
aws autoscaling set-desired-capacity --auto-scaling-group-name TrainingMoodleAutoScalingGroup --desired-capacity 0 --region ca-central-1
```

### 4.2 Restore Database

**Objective**: Import database backup to RDS

**Restoration Steps**:
```bash
# On EC2 instance or bastion host
# 1. Download database backup from S3
aws s3 cp s3://training-moodle-backups-{account}-ca-central-1/database/training_moodle_db.sql.gz /tmp/

# 2. Extract if compressed
gunzip /tmp/training_moodle_db.sql.gz

# 3. Get RDS credentials from Secrets Manager
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id TrainingMoodleDbSecret --region ca-central-1 --query SecretString --output text)
DB_HOST=$(echo $DB_SECRET | jq -r .host)
DB_USER=$(echo $DB_SECRET | jq -r .username)
DB_PASS=$(echo $DB_SECRET | jq -r .password)

# 4. Import database
mysql -h $DB_HOST -u $DB_USER -p$DB_PASS moodle < /tmp/training_moodle_db.sql

# 5. Verify import
mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -e "USE moodle; SELECT COUNT(*) FROM mdl_user;"
```

### 4.3 Restore Moodledata Files

**Objective**: Extract moodledata to EFS

**Restoration Steps**:
```bash
# On EC2 instance with EFS mounted
# 1. Download moodledata backup
aws s3 cp s3://training-moodle-backups-{account}-ca-central-1/moodledata/training_moodledata.tar.gz /tmp/

# 2. Extract to EFS data volume
cd /data
tar -xzf /tmp/training_moodledata.tar.gz

# 3. Set permissions
chown -R apache:apache /data/moodledata
chmod -R 755 /data/moodledata

# 4. Verify extraction
ls -la /data/moodledata
du -sh /data/moodledata
```

### 4.4 Deploy Moodle Code

**Objective**: Install Moodle 5.0 codebase

**Deployment Steps**:
```bash
# Clone Moodle 5.0
cd /app
git clone https://github.com/moodle/moodle.git
cd moodle
git branch --track MOODLE_500_STABLE origin/MOODLE_500_STABLE
git checkout MOODLE_500_STABLE

# Set permissions
chown -R apache:apache /app/moodle
chmod -R 755 /app/moodle
```

---

## Phase 5: Configuration & Testing

### 5.1 Create Moodle Configuration

**Objective**: Configure config.php for new environment

**Configuration Template**:
```php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = '{RDS_ENDPOINT}';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = '{DB_USER}';
$CFG->dbpass    = '{DB_PASS}';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = array(
  'dbpersist' => 0,
  'dbport' => 3306,
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

$CFG->wwwroot   = 'https://training.tsin.ca';
$CFG->dataroot  = '/data/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;

// Reverse proxy settings for ALB
$CFG->reverseproxy = false;
$CFG->sslproxy = false;

require_once(__DIR__ . '/lib/setup.php');
```

### 5.2 Run Moodle Upgrade

**Objective**: Update database schema to Moodle 5.0

**Upgrade Commands**:
```bash
cd /app/moodle
sudo -u apache php admin/cli/upgrade.php --non-interactive
sudo -u apache php admin/cli/purge_caches.php
```

### 5.3 Configure SES Email (Optional)

**Objective**: Set up AWS SES for email delivery

**Tasks**:
- [ ] Verify domain in SES: `training.tsin.ca`
- [ ] Configure SMTP settings in Moodle
- [ ] Test email delivery
- [ ] Use existing script: `scripts/configure-moodle-ses-email.sh`

### 5.4 Testing Checklist

**Functional Testing**:
- [ ] Login as admin
- [ ] Browse courses
- [ ] Test user enrollment
- [ ] Upload/download files
- [ ] Test quiz functionality
- [ ] Verify plugins are working
- [ ] Check theme rendering
- [ ] Test mobile responsiveness

**Performance Testing**:
- [ ] Load time < 3 seconds
- [ ] Database query performance
- [ ] File upload/download speed
- [ ] Concurrent user handling

**Security Testing**:
- [ ] HTTPS enforced
- [ ] Security headers present
- [ ] File permissions correct
- [ ] Database credentials secured

---

## Phase 6: DNS Cutover & Go-Live

### 6.1 Final Pre-Cutover Checks

**Checklist**:
- [ ] All tests passing
- [ ] Backup verified and tested
- [ ] Monitoring configured
- [ ] Alerts set up
- [ ] Rollback plan documented
- [ ] Stakeholders notified

### 6.2 DNS Update

**Objective**: Point training.tsin.ca to new ALB

**Steps**:
```powershell
# Get ALB DNS name
$albDns = aws cloudformation describe-stacks --stack-name TrainingMoodleCdkStack --region ca-central-1 --query "Stacks[0].Outputs[?OutputKey=='MoodleUrl'].OutputValue" --output text

# Update Route53 (or your DNS provider)
# Create/Update A record (Alias): training.tsin.ca → ALB
```

### 6.3 Post-Cutover Monitoring

**Monitoring Tasks** (First 24 hours):
- [ ] Monitor CloudWatch metrics
- [ ] Check error logs
- [ ] Verify user access
- [ ] Monitor performance
- [ ] Check email delivery
- [ ] Review security logs

### 6.4 Cleanup

**Tasks**:
- [ ] Remove temporary DNS records
- [ ] Delete local backup files (keep S3 copies)
- [ ] Remove migration lock files
- [ ] Update documentation
- [ ] Archive migration logs

---

## Key Differences from Learning.tsin.ca

| Aspect | Learning Stack | Training Stack | Shared? |
|--------|---------------|----------------|---------|
| Stack Name | `MoodleCdkStack` | `TrainingMoodleCdkStack` | ❌ |
| VPC | Created by stack | Imported from Learning | ✅ **Shared** |
| Subnets | Created by stack | Uses Learning subnets | ✅ **Shared** |
| NAT Gateways | Created by stack | Uses Learning NAT GWs | ✅ **Shared** |
| Domain | `elearning.tsin.ca` | `training.tsin.ca` | ❌ |
| RDS Database | `MoodleDatabase` | `TrainingMoodleDatabase` | ❌ Separate |
| EFS File Systems | `MoodleAppEfs`, `MoodleDataEfs` | `TrainingMoodleAppEfs`, `TrainingMoodleDataEfs` | ❌ Separate |
| ALB | `MoodleAlb` | `TrainingMoodleAlb` | ❌ Separate |
| ASG | `MoodleAutoScalingGroup` | `TrainingMoodleAutoScalingGroup` | ❌ Separate |
| Security Groups | `MoodleSecurityGroup`, etc. | `TrainingMoodleSecurityGroup`, etc. | ❌ Separate |
| S3 Bucket | `moodle-scripts-*` | `training-moodle-scripts-*` | ❌ Separate |
| Resource Prefix | `Moodle*` | `TrainingMoodle*` | ❌ |
| Tags | `Project: Moodle-CDK` | `Project: Training-Moodle-CDK` | ❌ |
| SFTP Source | N/A (fresh install) | `etraintouchstone@sftp-prod2-*` | ❌ |

**Key Benefits of Shared VPC**:
1. **Cost Savings**: ~$64/month saved on NAT Gateways
2. **Simplified Networking**: No need to manage VPC peering or Transit Gateway
3. **Faster Deployment**: VPC already exists, no need to create new one
4. **Resource Limits**: Doesn't count against VPC quota (5 VPCs per region by default)
5. **Security**: Separate security groups ensure complete isolation despite shared VPC

---

## Rollback Plan

### If Issues Occur During Migration:

1. **Before DNS Cutover**: Simply fix issues and retry
2. **After DNS Cutover**: 
   - Revert DNS to old server
   - Investigate and fix issues
   - Re-test before second cutover attempt

### Emergency Rollback Steps:
```powershell
# 1. Revert DNS immediately
# 2. Scale down new ASG
aws autoscaling set-desired-capacity --auto-scaling-group-name TrainingMoodleAutoScalingGroup --desired-capacity 0

# 3. Investigate logs
scripts/fetch-moodle-logs.ps1 -Stack TrainingMoodleCdkStack

# 4. Fix and redeploy when ready
```

---

## Success Criteria

- ✅ All infrastructure deployed successfully
- ✅ Database restored with all data intact
- ✅ All files accessible and correct permissions
- ✅ Moodle accessible via HTTPS
- ✅ All courses and users present
- ✅ No errors in logs
- ✅ Performance meets expectations
- ✅ Email delivery working
- ✅ Monitoring and alerts active

---

## Timeline Estimate

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Planning | 2-4 hours | None |
| Phase 2: Infrastructure | 30-45 min | Phase 1 complete |
| Phase 3: Backup Download | 1-3 hours | SFTP access, file sizes |
| Phase 4: Restoration | 2-4 hours | Backups downloaded |
| Phase 5: Testing | 4-8 hours | Restoration complete |
| Phase 6: Go-Live | 1-2 hours | All tests passing |
| **Total** | **1-2 days** | Assuming no major issues |

---

## Next Steps

1. Review and approve this migration plan
2. Verify SFTP access and backup availability
3. Create separate CDK stack for training.tsin.ca
4. Begin Phase 1 implementation


