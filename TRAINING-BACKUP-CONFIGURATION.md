# Training Moodle Backup Configuration

## Overview

Training Moodle has been successfully integrated into the existing AWS Backup infrastructure, using the same backup plan, schedule, and retention policies as Learning Moodle.

## Backup Configuration Summary

### Resources Backed Up

All Training Moodle resources with the `BackupEnabled=true` tag are automatically backed up:

| Resource Type | Resource ID | Backup Enabled |
|--------------|-------------|----------------|
| **RDS Database** | `trainingmoodlecdkstack-trainingmoodledatabasef2df4-y9g9jznqksao` | ✅ Yes |
| **EFS Data Filesystem** | `fs-0834ed0a16ccbb966` | ✅ Yes |
| **EFS App Filesystem** | `fs-0f028c598179df080` | ✅ Yes |

### Backup Plan Details

**Backup Plan Name**: `MoodleProductionBackupPlan`  
**Backup Plan ID**: `5d8adf3b-1c91-4f6c-9dac-855dca8b3c64`  
**Backup Vault**: `MoodleProductionBackups-*`  
**Encryption**: KMS encrypted with `alias/moodle-backup-key`

### Backup Schedule & Retention

Training Moodle follows the same multi-tier backup strategy as Learning Moodle:

| Backup Tier | Schedule | Retention | Cold Storage After | Resources |
|------------|----------|-----------|-------------------|-----------|
| **Hourly** | Every hour (`cron(0 * * * ? *)`) | 7 days | N/A | RDS only |
| **Daily** | 1:00 AM UTC (`cron(0 1 * * ? *)`) | 120 days | 30 days | All resources |
| **Weekly** | Sunday 2:00 AM UTC (`cron(0 2 ? * SUN *)`) | 365 days | 30 days | All resources |
| **Monthly** | 1st of month 3:00 AM UTC (`cron(0 3 1 * ? *)`) | 2,555 days (7 years) | 90 days | All resources |

### Backup Windows

- **Start Window**: 8 hours (480 minutes)
- **Completion Window**: 10-12 hours (depending on backup tier)

## Implementation Details

### CDK Changes

**File**: `lib/training-moodle-cdk-stack.ts`

Added backup tags to EFS filesystems (lines 164-166):

```typescript
// Add backup tags to EFS filesystems
cdk.Tags.of(dataFileSystem).add('BackupEnabled', 'true');
cdk.Tags.of(appFileSystem).add('BackupEnabled', 'true');
```

RDS database already had the backup tag (line 191):

```typescript
// Add backup tag to RDS database
cdk.Tags.of(dbInstance).add('BackupEnabled', 'true');
```

### Backup Selection

The existing backup selection in `MoodleBackupInfrastructureStack` automatically includes Training Moodle resources:

```typescript
const backupSelection = new backup.BackupSelection(this, 'MoodleBackupSelection', {
  backupPlan: backupPlan,
  resources: [
    // Only backup resources with this specific tag
    backup.BackupResource.fromTag('BackupEnabled', 'true'),
  ],
  allowRestores: true,
  backupSelectionName: 'MoodleProductionResources',
});
```

This tag-based selection means **both Learning and Training Moodle resources** are backed up by the same plan.

## Backup Storage

### Primary Backup Storage

- **S3 Bucket**: `moodle-production-backups-{account}-ca-central-1`
- **Versioning**: Enabled
- **Encryption**: KMS encrypted
- **Lifecycle Policy**:
  - 30 days → Infrequent Access (IA)
  - 90 days → Glacier
  - 365 days → Deep Archive
  - 2,555 days (7 years) → Expiration

### Cross-Region Replication

- **Replication Bucket**: `moodle-backup-replication-{account}-us-east-1`
- **Purpose**: Disaster recovery in secondary region
- **Encryption**: KMS encrypted

## Monitoring & Notifications

### SNS Topic

- **Topic Name**: `MoodleBackupNotifications-*`
- **Email Subscription**: Configured for backup job notifications
- **Events**: Success, failure, and warning notifications

### CloudWatch Logs

- **Log Group**: `/aws/backup/moodle-production`
- **Retention**: 30 days
- **Encryption**: KMS encrypted

## Recovery Procedures

### Restore from AWS Backup

1. **Navigate to AWS Backup Console**:
   - Go to: AWS Backup → Backup vaults → `MoodleProductionBackups-*`

2. **Select Recovery Point**:
   - Choose the backup you want to restore
   - Filter by resource type (RDS, EFS) and date

3. **Initiate Restore**:
   - Click "Restore"
   - Configure restore settings:
     - **RDS**: New instance or replace existing
     - **EFS**: New filesystem or restore to existing
   - Review and confirm

4. **Update Application Configuration**:
   - If restoring to new resources, update Training Moodle configuration
   - Update DNS if necessary
   - Test application functionality

### Manual Database Restore

For point-in-time recovery or manual restore:

```bash
# Download backup from S3
aws s3 cp s3://moodle-production-backups-{account}-ca-central-1/training/ /tmp/backup/

# Restore to RDS
mysql -h trainingmoodlecdkstack-trainingmoodledatabasef2df4-y9g9jznqksao.crx38jxk1vhe.ca-central-1.rds.amazonaws.com \
  -u trainmoodleadm -p moodle < /tmp/backup/database.sql
```

### EFS Restore

AWS Backup handles EFS restores automatically. For manual file recovery:

```bash
# Mount EFS filesystem
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  fs-0834ed0a16ccbb966.efs.ca-central-1.amazonaws.com:/ /mnt/efs-data

# Restore specific files
aws backup start-restore-job \
  --recovery-point-arn arn:aws:backup:ca-central-1:{account}:recovery-point:{id} \
  --metadata file-system-id=fs-0834ed0a16ccbb966,Encrypted=false,PerformanceMode=generalPurpose
```

## Verification

### Verify Backup Tags

Run the verification script:

```powershell
pwsh scripts/verify-training-backup-tags.ps1
```

Expected output:
- ✅ Data EFS: `BackupEnabled=true`
- ✅ App EFS: `BackupEnabled=true`
- ✅ RDS Database: `BackupEnabled=true`
- ✅ Backup Plan: `MoodleProductionBackupPlan` active
- ✅ Backup Rules: Hourly, Daily, Weekly, Monthly

### Check Backup Jobs

```bash
# List recent backup jobs
aws backup list-backup-jobs --region ca-central-1 \
  --by-resource-type EFS \
  --max-results 10

aws backup list-backup-jobs --region ca-central-1 \
  --by-resource-type RDS \
  --max-results 10
```

### View Recovery Points

```bash
# List recovery points for Training Moodle RDS
aws backup list-recovery-points-by-resource \
  --resource-arn arn:aws:rds:ca-central-1:{account}:db:trainingmoodlecdkstack-trainingmoodledatabasef2df4-y9g9jznqksao \
  --region ca-central-1

# List recovery points for Training Moodle EFS
aws backup list-recovery-points-by-resource \
  --resource-arn arn:aws:elasticfilesystem:ca-central-1:{account}:file-system/fs-0834ed0a16ccbb966 \
  --region ca-central-1
```

## Cost Considerations

### Backup Storage Costs

- **AWS Backup**: $0.05 per GB-month (warm storage)
- **Cold Storage**: $0.01 per GB-month (after lifecycle transition)
- **Restore**: $0.02 per GB

### Estimated Monthly Costs (Training Moodle)

Assuming:
- RDS: 100 GB database
- EFS Data: 50 GB
- EFS App: 10 GB
- Total: 160 GB

| Backup Tier | Storage | Cost/Month |
|------------|---------|------------|
| Hourly (7 days) | ~160 GB × 7 | $56 |
| Daily (120 days) | ~160 GB × 30 (warm) + 90 (cold) | $192 |
| Weekly (365 days) | ~160 GB × 30 (warm) + 335 (cold) | $293 |
| Monthly (7 years) | ~160 GB × 90 (warm) + 2465 (cold) | $1,664 |
| **Total** | | **~$2,205/month** |

**Note**: Actual costs will vary based on data growth and deduplication.

## Best Practices

1. **Regular Testing**: Test restore procedures quarterly
2. **Monitor Backup Jobs**: Review CloudWatch logs and SNS notifications
3. **Retention Review**: Adjust retention policies based on compliance requirements
4. **Cost Optimization**: Review backup storage usage monthly
5. **Documentation**: Keep recovery procedures up-to-date
6. **Access Control**: Limit backup restore permissions to authorized personnel

## Related Resources

- **Backup Infrastructure Stack**: `lib/backup-infrastructure-stack.ts`
- **Training Moodle Stack**: `lib/training-moodle-cdk-stack.ts`
- **Verification Script**: `scripts/verify-training-backup-tags.ps1`
- **AWS Backup Console**: https://console.aws.amazon.com/backup/
- **CloudWatch Logs**: https://console.aws.amazon.com/cloudwatch/

## Support

For backup-related issues:
1. Check AWS Backup console for job status
2. Review CloudWatch logs for errors
3. Verify IAM permissions for backup service role
4. Contact AWS Support if needed

---

**Last Updated**: 2025-10-21  
**Status**: ✅ Active and Operational

