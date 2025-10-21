import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as efs from 'aws-cdk-lib/aws-efs';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as cr from 'aws-cdk-lib/custom-resources';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import { Construct } from 'constructs';

/**
 * Training Moodle CDK Stack
 * 
 * This stack deploys a separate Moodle instance for training.tsin.ca
 * that shares the VPC with the existing learning.tsin.ca instance but
 * has completely separate:
 * - RDS Database
 * - EFS File Systems
 * - Application Load Balancer
 * - Auto Scaling Group
 * - Security Groups
 * - S3 Buckets
 * 
 * This ensures complete isolation between the two Moodle instances
 * while sharing network infrastructure to reduce costs.
 */
export class TrainingMoodleCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ========================================================================
    // Import Existing VPC from Learning Moodle Stack
    // ========================================================================
    
    // Look up the existing VPC by tag or ID
    // The VPC was created by MoodleCdkStack
    const vpc = ec2.Vpc.fromLookup(this, 'ExistingVpc', {
      // Option 1: Look up by tag
      tags: {
        'aws:cloudformation:stack-name': 'MoodleCdkStack'
      }
      // Option 2: If you know the VPC ID, you can use:
      // vpcId: 'vpc-xxxxxxxxx'
    });

    // ========================================================================
    // CloudWatch Log Groups (Separate for Training)
    // ========================================================================
    
    const moodleLogGroup = new logs.LogGroup(this, 'TrainingMoodleLogGroup', {
      logGroupName: '/aws/ec2/training-moodle',
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const systemLogGroup = new logs.LogGroup(this, 'TrainingSystemLogGroup', {
      logGroupName: '/aws/ec2/training-system',
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ========================================================================
    // S3 Bucket for Scripts (Separate for Training)
    // ========================================================================
    
    const scriptsBucket = new s3.Bucket(this, 'TrainingMoodleScriptsBucket', {
      bucketName: `training-moodle-scripts-${this.account}-${this.region}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Deploy scripts to S3
    const skipScriptsCtx = (this.node.tryGetContext('SkipScriptDeployment') ?? process.env.SKIP_SCRIPT_DEPLOYMENT ?? 'false').toString().toLowerCase();
    if (skipScriptsCtx !== 'true') {
      new s3deploy.BucketDeployment(this, 'DeployTrainingMoodleScripts', {
        sources: [s3deploy.Source.asset('./scripts')],
        destinationBucket: scriptsBucket,
      });
    }

    // ========================================================================
    // Database Credentials Secret (Separate for Training)
    // ========================================================================
    
    const dbSecret = new secretsmanager.Secret(this, 'TrainingMoodleDbSecret', {
      description: 'MariaDB credentials for Training Moodle',
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: 'trainmoodleadm' }),
        generateStringKey: 'password',
        excludeCharacters: '"@/\\\'',
        passwordLength: 32,
      },
    });

    // ========================================================================
    // Security Groups (Separate for Training)
    // ========================================================================
    
    const albSecurityGroup = new ec2.SecurityGroup(this, 'TrainingAlbSecurityGroup', {
      vpc,
      description: 'Security group for Training Moodle Application Load Balancer',
      allowAllOutbound: true,
    });
    albSecurityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(80), 'Allow HTTP traffic');
    albSecurityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), 'Allow HTTPS traffic');

    const moodleSecurityGroup = new ec2.SecurityGroup(this, 'TrainingMoodleSecurityGroup', {
      vpc,
      description: 'Security group for Training Moodle EC2 instances',
      allowAllOutbound: true,
    });
    moodleSecurityGroup.addIngressRule(albSecurityGroup, ec2.Port.tcp(80), 'Allow HTTP from ALB');

    const dbSecurityGroup = new ec2.SecurityGroup(this, 'TrainingDbSecurityGroup', {
      vpc,
      description: 'Security group for Training Moodle RDS database',
      allowAllOutbound: false,
    });
    dbSecurityGroup.addIngressRule(moodleSecurityGroup, ec2.Port.tcp(3306), 'Allow MySQL from Moodle instances');

    const efsSecurityGroup = new ec2.SecurityGroup(this, 'TrainingEfsSecurityGroup', {
      vpc,
      description: 'Security group for Training Moodle EFS',
      allowAllOutbound: false,
    });
    efsSecurityGroup.addIngressRule(moodleSecurityGroup, ec2.Port.tcp(2049), 'Allow NFS from Moodle');

    // ========================================================================
    // EFS File Systems (Separate for Training)
    // ========================================================================
    
    const dataFileSystem = new efs.FileSystem(this, 'TrainingMoodleDataEfs', {
      vpc,
      lifecyclePolicy: efs.LifecyclePolicy.AFTER_30_DAYS,
      performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode: efs.ThroughputMode.BURSTING,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      securityGroup: efsSecurityGroup,
    });

    const appFileSystem = new efs.FileSystem(this, 'TrainingMoodleAppEfs', {
      vpc,
      lifecyclePolicy: efs.LifecyclePolicy.AFTER_30_DAYS,
      performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode: efs.ThroughputMode.BURSTING,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      securityGroup: efsSecurityGroup,
    });

    // ========================================================================
    // RDS Database (Separate for Training)
    // ========================================================================

    // Use default parameter group for MariaDB 10.11 to avoid parameter issues (same as learning stack)

    const dbInstance = new rds.DatabaseInstance(this, 'TrainingMoodleDatabase', {
      engine: rds.DatabaseInstanceEngine.mariaDb({
        version: rds.MariaDbEngineVersion.VER_10_11,
      }),
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.M7I, ec2.InstanceSize.XLARGE),
      credentials: rds.Credentials.fromSecret(dbSecret),
      vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
      },
      securityGroups: [dbSecurityGroup],
      multiAz: true,
      storageEncrypted: true,
      backupRetention: cdk.Duration.days(7),
      deletionProtection: false,
      databaseName: 'moodle',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      cloudwatchLogsExports: ['error', 'general'],
    });

    // Add backup tag to RDS database
    cdk.Tags.of(dbInstance).add('BackupEnabled', 'true');

    // ========================================================================
    // Application Load Balancer (Separate for Training)
    // ========================================================================
    
    const alb = new elbv2.ApplicationLoadBalancer(this, 'TrainingMoodleAlb', {
      vpc,
      internetFacing: true,
      securityGroup: albSecurityGroup,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
      },
    });

    const targetGroup = new elbv2.ApplicationTargetGroup(this, 'TrainingMoodleTargetGroup', {
      vpc,
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.INSTANCE,
      healthCheck: {
        enabled: true,
        path: '/health.php',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
        healthyHttpCodes: '200',
      },
      deregistrationDelay: cdk.Duration.seconds(30),
      stickinessCookieDuration: cdk.Duration.hours(1),
      stickinessCookieName: 'TRAINING_MOODLE_SESSION',
    });

    // Import existing ACM certificate for training.tsin.ca
    const certificate = acm.Certificate.fromCertificateArn(
      this,
      'TrainingMoodleCertificate',
      'arn:aws:acm:ca-central-1:483382415631:certificate/82a36a4a-6067-4074-9a83-d709ca8a311d'
    );

    // HTTPS Listener (primary)
    alb.addListener('TrainingHttpsListener', {
      port: 443,
      protocol: elbv2.ApplicationProtocol.HTTPS,
      certificates: [certificate],
      defaultAction: elbv2.ListenerAction.forward([targetGroup]),
    });

    // HTTP Listener (redirect to HTTPS)
    alb.addListener('TrainingHttpListener', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      defaultAction: elbv2.ListenerAction.redirect({
        protocol: 'HTTPS',
        port: '443',
        permanent: true,
      }),
    });

    // ========================================================================
    // IAM Role for EC2 Instances (Separate for Training)
    // ========================================================================
    
    const instanceRole = new iam.Role(this, 'TrainingMoodleInstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
      ],
    });

    // Grant permissions
    dbSecret.grantRead(instanceRole);
    scriptsBucket.grantRead(instanceRole);
    dataFileSystem.grant(instanceRole, 'elasticfilesystem:ClientMount', 'elasticfilesystem:ClientWrite');
    appFileSystem.grant(instanceRole, 'elasticfilesystem:ClientMount', 'elasticfilesystem:ClientWrite');

    instanceRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'cloudformation:DescribeStacks',
        'cloudformation:DescribeStackResources',
        'ec2:DescribeInstances',
        'ec2:DescribeTags',
        'autoscaling:DescribeAutoScalingGroups',
        'autoscaling:SetInstanceProtection',
        'elasticfilesystem:DescribeFileSystems',
        'elasticfilesystem:DescribeMountTargets',
        'elasticfilesystem:DescribeMountTargetSecurityGroups',
        'secretsmanager:ListSecrets',
      ],
      resources: ['*'],
    }));

    // Grant S3 access for backups
    instanceRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['s3:GetObject', 's3:PutObject', 's3:ListBucket'],
      resources: [
        `arn:aws:s3:::training-moodle-backups-${this.account}-${this.region}`,
        `arn:aws:s3:::training-moodle-backups-${this.account}-${this.region}/*`,
      ],
    }));

    // Grant access to SES SMTP credentials secret (shared with Learning Moodle)
    instanceRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['secretsmanager:GetSecretValue'],
      resources: [`arn:aws:secretsmanager:${this.region}:${this.account}:secret:moodle/ses/smtp-credentials-*`],
    }));

    // Grant access to SES SSM parameters (shared with Learning Moodle)
    instanceRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['ssm:GetParameter', 'ssm:GetParameters'],
      resources: [
        `arn:aws:ssm:${this.region}:${this.account}:parameter/moodle/ses/*`,
      ],
    }));

    // Grant SES email sending permissions
    instanceRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['ses:SendEmail', 'ses:SendRawEmail', 'ses:SendTemplatedEmail', 'ses:SendBulkTemplatedEmail'],
      resources: ['*'],
      conditions: {
        StringEquals: {
          'ses:FromAddress': ['noreply@tsin.ca', 'noreply@training.tsin.ca', 'it@tsin.ca'],
        },
      },
    }));

    // ========================================================================
    // Launch Template (Separate for Training)
    // ========================================================================
    
    const launchTemplate = new ec2.LaunchTemplate(this, 'TrainingMoodleLaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.M7I, ec2.InstanceSize.XLARGE),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.X86_64,
      }),
      securityGroup: moodleSecurityGroup,
      role: instanceRole,
      requireImdsv2: true,
      userData: this.createUserData(
        appFileSystem.fileSystemId,
        dataFileSystem.fileSystemId,
        dbInstance.dbInstanceEndpointAddress,
        dbSecret.secretArn,
        efsSecurityGroup.securityGroupId,
        `https://training.tsin.ca`, // Update this with actual domain
        scriptsBucket.bucketName
      ),
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(30, {
          volumeType: ec2.EbsDeviceVolumeType.GP3,
          encrypted: true,
        }),
      }],
    });

    // ========================================================================
    // Auto Scaling Group (Separate for Training)
    // ========================================================================
    
    const autoScalingGroup = new autoscaling.AutoScalingGroup(this, 'TrainingMoodleAutoScalingGroup', {
      vpc,
      launchTemplate: launchTemplate,
      minCapacity: 2,
      maxCapacity: 4,
      desiredCapacity: 2,

      // Protect new instances from scale-in by default
      newInstancesProtectedFromScaleIn: true,

      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      healthCheck: autoscaling.HealthCheck.elb({
        grace: cdk.Duration.minutes(45),
      }),
      updatePolicy: autoscaling.UpdatePolicy.rollingUpdate({
        maxBatchSize: 1,
        minInstancesInService: 0,
        pauseTime: cdk.Duration.minutes(10),
      }),
    });

    autoScalingGroup.attachToApplicationTargetGroup(targetGroup);

    // Scaling policies
    autoScalingGroup.scaleOnCpuUtilization('TrainingCpuScaling', {
      targetUtilizationPercent: 70,
      cooldown: cdk.Duration.minutes(5),
    });

    autoScalingGroup.scaleOnRequestCount('TrainingRequestCountScaling', {
      targetRequestsPerMinute: 1000,
    });

    // ========================================================================
    // Outputs
    // ========================================================================

    new cdk.CfnOutput(this, 'TrainingMoodleUrl', {
      value: 'https://training.tsin.ca',
      description: 'Training Moodle Custom Domain URL',
    });

    new cdk.CfnOutput(this, 'TrainingMoodleAlbDns', {
      value: alb.loadBalancerDnsName,
      description: 'Training Moodle Application Load Balancer DNS Name (for Route53 setup)',
    });

    new cdk.CfnOutput(this, 'TrainingDatabaseEndpoint', {
      value: dbInstance.dbInstanceEndpointAddress,
      description: 'Training Moodle RDS Database Endpoint',
    });

    new cdk.CfnOutput(this, 'TrainingDatabaseSecretArn', {
      value: dbSecret.secretArn,
      description: 'Training Moodle Database Secret ARN',
    });

    new cdk.CfnOutput(this, 'TrainingAppEfsId', {
      value: appFileSystem.fileSystemId,
      description: 'Training Moodle App EFS File System ID',
    });

    new cdk.CfnOutput(this, 'TrainingDataEfsId', {
      value: dataFileSystem.fileSystemId,
      description: 'Training Moodle Data EFS File System ID',
    });

    new cdk.CfnOutput(this, 'TrainingScriptsBucket', {
      value: scriptsBucket.bucketName,
      description: 'Training Moodle Scripts S3 Bucket',
    });
  }

  // User data creation method (reuse from main stack with training-specific values)
  private createUserData(
    appEfsId: string,
    dataEfsId: string,
    dbEndpoint: string,
    dbSecretArn: string,
    efsSgId: string,
    moodleWwwroot: string,
    scriptBucket: string
  ): ec2.UserData {
    const userData = ec2.UserData.forLinux();
    
    // Similar to main stack but with training-specific environment variables
    userData.addCommands(
      '#!/bin/bash',
      'set -euo pipefail',
      '',
      '# Logging setup',
      'exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1',
      'echo "Starting Training Moodle installation script at $(date)"',
      '',
      '# Set environment variables',
      `export APP_EFS_ID="${appEfsId}"`,
      `export DATA_EFS_ID="${dataEfsId}"`,
      `export DB_ENDPOINT="${dbEndpoint}"`,
      `export DB_SECRET_ARN="${dbSecretArn}"`,
      `export AWS_REGION="${this.region}"`,
      `export REGION="${this.region}"`,
      'export MOODLE_SITE_NAME="Touchstone Institute Training"',
      'export MOODLE_ADMIN_USER="training-admin"',
      'export MOODLE_ADMIN_EMAIL="it@tsin.ca"',
      `export EFS_SG_ID="${efsSgId}"`,
      `export MOODLE_WWWROOT="${moodleWwwroot}"`,
      `export SCRIPT_BUCKET="${scriptBucket}"`,
      'export MULTI_INSTANCE_SAFE=1',
      'export ALLOW_DESTRUCTIVE=0',
      '',
      '# Download and execute bootstrap script',
      'aws s3 cp "s3://$SCRIPT_BUCKET/bootstrap-moodle.sh" /tmp/bootstrap-moodle.sh',
      'chmod +x /tmp/bootstrap-moodle.sh',
      '/tmp/bootstrap-moodle.sh'
    );
    
    return userData;
  }
}

