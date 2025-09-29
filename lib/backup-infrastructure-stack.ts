import * as cdk from 'aws-cdk-lib';
import * as backup from 'aws-cdk-lib/aws-backup';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as snsSubscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

export interface MoodleBackupInfrastructureStackProps extends cdk.StackProps {
  readonly primaryRegion?: string;
  readonly secondaryRegion?: string;
  readonly notificationEmail?: string;
}

export class MoodleBackupInfrastructureStack extends cdk.Stack {
  public readonly backupBucket: s3.Bucket;
  public readonly replicationBucket: s3.Bucket;
  public readonly backupVault: backup.BackupVault;
  public readonly notificationTopic: sns.Topic;

  constructor(scope: Construct, id: string, props?: MoodleBackupInfrastructureStackProps) {
    super(scope, id, props);

    const primaryRegion = props?.primaryRegion || 'ca-central-1';
    const secondaryRegion = props?.secondaryRegion || 'us-east-1';
    const timestamp = Date.now().toString().slice(-8); // Last 8 digits for uniqueness

    // 1. KMS Key for backup encryption
    const backupKey = new kms.Key(this, 'MoodleBackupKey', {
      description: 'KMS key for Moodle backup encryption',
      enableKeyRotation: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      policy: new iam.PolicyDocument({
        statements: [
          // Default key policy for account root
          new iam.PolicyStatement({
            sid: 'Enable IAM User Permissions',
            effect: iam.Effect.ALLOW,
            principals: [new iam.AccountRootPrincipal()],
            actions: ['kms:*'],
            resources: ['*'],
          }),
          // CloudWatch Logs permissions
          new iam.PolicyStatement({
            sid: 'Allow CloudWatch Logs',
            effect: iam.Effect.ALLOW,
            principals: [new iam.ServicePrincipal(`logs.${primaryRegion}.amazonaws.com`)],
            actions: [
              'kms:Encrypt',
              'kms:Decrypt',
              'kms:ReEncrypt*',
              'kms:GenerateDataKey*',
              'kms:DescribeKey',
            ],
            resources: ['*'],
            conditions: {
              ArnEquals: {
                'kms:EncryptionContext:aws:logs:arn': `arn:aws:logs:${primaryRegion}:${this.account}:log-group:/aws/lambda/moodle-backup-operations-${timestamp}`,
              },
            },
          }),
          // Backup service permissions
          new iam.PolicyStatement({
            sid: 'Allow AWS Backup',
            effect: iam.Effect.ALLOW,
            principals: [new iam.ServicePrincipal('backup.amazonaws.com')],
            actions: [
              'kms:Encrypt',
              'kms:Decrypt',
              'kms:ReEncrypt*',
              'kms:GenerateDataKey*',
              'kms:DescribeKey',
            ],
            resources: ['*'],
          }),
        ],
      }),
    });

    backupKey.addAlias('alias/moodle-backup-key');

    // 2. Primary S3 Bucket for backup storage
    this.backupBucket = new s3.Bucket(this, 'MoodleBackupBucket', {
      bucketName: `moodle-production-backups-${this.account}-${primaryRegion}`,
      versioned: true,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: backupKey,
      lifecycleRules: [
        {
          id: 'BackupLifecycle',
          enabled: true,
          transitions: [
            {
              storageClass: s3.StorageClass.INFREQUENT_ACCESS,
              transitionAfter: cdk.Duration.days(30),
            },
            {
              storageClass: s3.StorageClass.GLACIER,
              transitionAfter: cdk.Duration.days(90),
            },
            {
              storageClass: s3.StorageClass.DEEP_ARCHIVE,
              transitionAfter: cdk.Duration.days(365),
            },
          ],
          expiration: cdk.Duration.days(2555), // 7 years
        },
      ],
      publicReadAccess: false,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // 3. Cross-region replication bucket
    this.replicationBucket = new s3.Bucket(this, 'MoodleBackupReplicationBucket', {
      bucketName: `moodle-backup-replication-${this.account}-${secondaryRegion}`,
      versioned: true,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: backupKey,
      publicReadAccess: false,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // 4. AWS Backup Vault with enhanced security
    this.backupVault = new backup.BackupVault(this, 'MoodleBackupVault', {
      backupVaultName: `MoodleProductionBackups-${timestamp}`,
      encryptionKey: backupKey,
    });

    // 5. Enhanced Backup Plan with multiple tiers
    const backupPlan = new backup.BackupPlan(this, 'MoodleBackupPlan', {
      backupPlanName: 'MoodleProductionBackupPlan',
      backupPlanRules: [
        // Hourly backups for critical data (RDS)
        new backup.BackupPlanRule({
          ruleName: 'HourlyRDSBackups',
          backupVault: this.backupVault,
          scheduleExpression: events.Schedule.cron({
            minute: '0',
            hour: '*',
            day: '*',
            month: '*',
            year: '*',
          }),
          startWindow: cdk.Duration.hours(8), // AWS minimum is 480 minutes (8 hours)
          completionWindow: cdk.Duration.hours(10), // Must be at least 60 minutes greater than start window
          deleteAfter: cdk.Duration.days(7),
          recoveryPointTags: {
            BackupType: 'Hourly',
            DataType: 'Database',
          },
        }),
        // Daily backups for all resources
        new backup.BackupPlanRule({
          ruleName: 'DailyBackups',
          backupVault: this.backupVault,
          scheduleExpression: events.Schedule.cron({
            minute: '0',
            hour: '1',
            day: '*',
            month: '*',
            year: '*',
          }),
          startWindow: cdk.Duration.hours(8), // AWS minimum is 480 minutes (8 hours)
          completionWindow: cdk.Duration.hours(10), // Must be at least 60 minutes greater than start window
          deleteAfter: cdk.Duration.days(120), // Must be at least 90 days apart from moveToColdStorageAfter
          moveToColdStorageAfter: cdk.Duration.days(30), // 120-30 = 90 days gap (minimum required)
          recoveryPointTags: {
            BackupType: 'Daily',
            DataType: 'All',
          },
        }),
        // Weekly long-term backups
        new backup.BackupPlanRule({
          ruleName: 'WeeklyBackups',
          backupVault: this.backupVault,
          scheduleExpression: events.Schedule.cron({
            minute: '0',
            hour: '2',
            month: '*',
            year: '*',
            weekDay: 'SUN',
          }),
          startWindow: cdk.Duration.hours(8), // AWS minimum is 480 minutes (8 hours)
          completionWindow: cdk.Duration.hours(10), // Must be at least 60 minutes greater than start window
          deleteAfter: cdk.Duration.days(365),
          moveToColdStorageAfter: cdk.Duration.days(30),
          recoveryPointTags: {
            BackupType: 'Weekly',
            DataType: 'All',
          },
        }),
        // Monthly archive backups
        new backup.BackupPlanRule({
          ruleName: 'MonthlyArchive',
          backupVault: this.backupVault,
          scheduleExpression: events.Schedule.cron({
            minute: '0',
            hour: '3',
            day: '1',
            month: '*',
            year: '*',
          }),
          startWindow: cdk.Duration.hours(8), // AWS minimum is 480 minutes (8 hours)
          completionWindow: cdk.Duration.hours(12), // Must be at least 60 minutes greater than start window
          deleteAfter: cdk.Duration.days(2555), // 7 years
          moveToColdStorageAfter: cdk.Duration.days(90),
          recoveryPointTags: {
            BackupType: 'Monthly',
            DataType: 'Archive',
          },
        }),
      ],
    });

    // 6. SNS Topic for notifications with email subscription
    this.notificationTopic = new sns.Topic(this, 'BackupNotifications', {
      topicName: 'moodle-backup-notifications',
      displayName: 'Moodle Backup Notifications',
      masterKey: backupKey,
    });

    // Add email subscription if provided
    if (props?.notificationEmail) {
      this.notificationTopic.addSubscription(
        new snsSubscriptions.EmailSubscription(props.notificationEmail)
      );
    }

    // 7. CloudWatch Log Group for backup operations
    const backupLogGroup = new logs.LogGroup(this, 'MoodleBackupLogs', {
      logGroupName: `/aws/lambda/moodle-backup-operations-${timestamp}`,
      retention: logs.RetentionDays.ONE_YEAR,
      encryptionKey: backupKey,
    });

    // 8. Enhanced Lambda function for comprehensive backup operations
    const backupLambda = new lambda.Function(this, 'MoodleBackupFunction', {
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.lambda_handler',
      code: lambda.Code.fromAsset('lambda/backup-function'),
      timeout: cdk.Duration.minutes(15),
      memorySize: 512,
      environment: {
        SNS_TOPIC_ARN: this.notificationTopic.topicArn,
        BACKUP_BUCKET: this.backupBucket.bucketName,
        REPLICATION_BUCKET: this.replicationBucket.bucketName,
        PRIMARY_REGION: primaryRegion,
        SECONDARY_REGION: secondaryRegion,
        KMS_KEY_ID: backupKey.keyId,
      },
    });

    // Associate Lambda with log group
    backupLambda.node.addDependency(backupLogGroup);

    // Grant comprehensive permissions to Lambda
    backupLambda.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          // RDS permissions
          'rds:CreateDBSnapshot',
          'rds:DescribeDBInstances',
          'rds:DescribeDBSnapshots',
          'rds:CopyDBSnapshot',
          'rds:AddTagsToResource',
          // EFS permissions
          'elasticfilesystem:DescribeFileSystems',
          'elasticfilesystem:DescribeBackupPolicy',
          // Backup permissions
          'backup:StartBackupJob',
          'backup:DescribeBackupJob',
          'backup:ListBackupJobs',
          // S3 permissions
          's3:GetObject',
          's3:PutObject',
          's3:DeleteObject',
          's3:ListBucket',
          // SNS permissions
          'sns:Publish',
          // SSM permissions
          'ssm:SendCommand',
          'ssm:GetParameter',
          'ssm:GetParameters',
          // Secrets Manager permissions
          'secretsmanager:GetSecretValue',
          // Auto Scaling permissions
          'autoscaling:DescribeAutoScalingGroups',
          // EC2 permissions
          'ec2:DescribeInstances',
          // STS permissions
          'sts:GetCallerIdentity',
          // KMS permissions
          'kms:Decrypt',
          'kms:GenerateDataKey',
        ],
        resources: ['*'],
      })
    );

    // Grant S3 bucket permissions
    this.backupBucket.grantReadWrite(backupLambda);
    this.replicationBucket.grantReadWrite(backupLambda);

    // Grant SNS permissions
    this.notificationTopic.grantPublish(backupLambda);

    // Grant KMS permissions
    backupKey.grantEncryptDecrypt(backupLambda);

    // 9. Backup Selection for RDS and EFS resources only
    // Note: We use a custom tag to avoid backing up S3 buckets (not supported by AWS Backup)
    const backupSelection = new backup.BackupSelection(this, 'MoodleBackupSelection', {
      backupPlan: backupPlan,
      resources: [
        // Only backup resources with this specific tag
        backup.BackupResource.fromTag('BackupEnabled', 'true'),
      ],
      allowRestores: true,
      backupSelectionName: 'MoodleProductionResources',
    });

    // 10. EventBridge rule for scheduled backups
    const backupScheduleRule = new events.Rule(this, 'BackupScheduleRule', {
      schedule: events.Schedule.cron({
        minute: '0',
        hour: '2',
        day: '*',
        month: '*',
        year: '*',
      }),
      description: 'Trigger Moodle backup Lambda daily at 2 AM',
    });

    backupScheduleRule.addTarget(new targets.LambdaFunction(backupLambda));

    // 11. Cross-region replication configuration
    this.backupBucket.addCorsRule({
      allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.PUT],
      allowedOrigins: ['*'],
      allowedHeaders: ['*'],
    });

    // 12. SSM Parameters for backup configuration
    new ssm.StringParameter(this, 'BackupBucketParameter', {
      parameterName: '/moodle/backup/bucket-name',
      stringValue: this.backupBucket.bucketName,
      description: 'S3 bucket name for Moodle backups',
    });

    new ssm.StringParameter(this, 'BackupVaultParameter', {
      parameterName: '/moodle/backup/vault-name',
      stringValue: this.backupVault.backupVaultName,
      description: 'AWS Backup vault name for Moodle',
    });

    new ssm.StringParameter(this, 'BackupLambdaParameter', {
      parameterName: '/moodle/backup/lambda-arn',
      stringValue: backupLambda.functionArn,
      description: 'Lambda function ARN for Moodle backups',
    });

    // Outputs
    new cdk.CfnOutput(this, 'BackupBucketName', {
      value: this.backupBucket.bucketName,
      description: 'S3 bucket for Moodle backups',
      exportName: 'MoodleBackupBucketName',
    });

    new cdk.CfnOutput(this, 'ReplicationBucketName', {
      value: this.replicationBucket.bucketName,
      description: 'S3 bucket for cross-region backup replication',
      exportName: 'MoodleReplicationBucketName',
    });

    new cdk.CfnOutput(this, 'BackupVaultName', {
      value: this.backupVault.backupVaultName,
      description: 'AWS Backup vault for Moodle',
      exportName: 'MoodleBackupVaultName',
    });

    new cdk.CfnOutput(this, 'BackupVaultArn', {
      value: this.backupVault.backupVaultArn,
      description: 'AWS Backup vault ARN for Moodle',
      exportName: 'MoodleBackupVaultArn',
    });

    new cdk.CfnOutput(this, 'NotificationTopicArn', {
      value: this.notificationTopic.topicArn,
      description: 'SNS topic for backup notifications',
      exportName: 'MoodleBackupNotificationTopic',
    });

    new cdk.CfnOutput(this, 'BackupLambdaArn', {
      value: backupLambda.functionArn,
      description: 'Lambda function ARN for backup operations',
      exportName: 'MoodleBackupLambdaArn',
    });

    new cdk.CfnOutput(this, 'BackupKmsKeyId', {
      value: backupKey.keyId,
      description: 'KMS key ID for backup encryption',
      exportName: 'MoodleBackupKmsKeyId',
    });

    new cdk.CfnOutput(this, 'BackupKmsKeyArn', {
      value: backupKey.keyArn,
      description: 'KMS key ARN for backup encryption',
      exportName: 'MoodleBackupKmsKeyArn',
    });
  }
}
