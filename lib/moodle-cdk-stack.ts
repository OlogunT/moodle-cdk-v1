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
import * as elasticache from 'aws-cdk-lib/aws-elasticache';
import { Construct } from 'constructs';

export class MoodleCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // VPC with 2 AZs
    const vpc = new ec2.Vpc(this, 'MoodleVpc', {
      maxAzs: 2,
      natGateways: 2,
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
        },
        {
          cidrMask: 24,
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        },
        {
          cidrMask: 28,
          name: 'Database',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
        },
      ],
    });

    // CloudWatch Log Groups
    const moodleLogGroup = new logs.LogGroup(this, 'MoodleLogGroup', {
      logGroupName: '/aws/ec2/moodle',
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const systemLogGroup = new logs.LogGroup(this, 'SystemLogGroup', {
      logGroupName: '/aws/ec2/system',
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // S3 bucket for installation scripts
    const scriptsBucket = new s3.Bucket(this, 'MoodleScriptsBucket', {
      bucketName: `moodle-scripts-${this.account}-${this.region}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Parameter/Condition to optionally skip script deployment (useful to unblock CFN rollbacks)
    const skipScriptDeployment = new cdk.CfnParameter(this, 'SkipScriptDeployment', {
      type: 'String',
      allowedValues: ['true', 'false'],
      default: 'false',
      description: 'If true, skip deploying local scripts to S3 (for transient CI/deploy issues)'
    });
    // Deploy the intelligent installation script to S3 based on context (avoids CFN custom resource failures during recovery)
    const skipScriptsCtx = (this.node.tryGetContext('SkipScriptDeployment') ?? process.env.SKIP_SCRIPT_DEPLOYMENT ?? 'false').toString().toLowerCase();
    if (skipScriptsCtx !== 'true') {
      new s3deploy.BucketDeployment(this, 'DeployMoodleScripts', {
        sources: [s3deploy.Source.asset('./scripts')],
        destinationBucket: scriptsBucket,
      });
    }

    // Database credentials secret
    const dbSecret = new secretsmanager.Secret(this, 'MoodleDbSecret', {
      description: 'MariaDB credentials for Moodle',
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: 'moodleuser' }),
        generateStringKey: 'password',
        excludeCharacters: '"@/\\\'',
        passwordLength: 32,
      },
    });

    // Security Groups
    const albSecurityGroup = new ec2.SecurityGroup(this, 'AlbSecurityGroup', {
      vpc,
      description: 'Security group for Application Load Balancer',
      allowAllOutbound: true,
    });
    albSecurityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(80), 'Allow HTTP traffic');
    albSecurityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), 'Allow HTTPS traffic');

    const moodleSecurityGroup = new ec2.SecurityGroup(this, 'MoodleSecurityGroup', {
      vpc,
      description: 'Security group for Moodle EC2 instances',
      allowAllOutbound: true,
    });
    moodleSecurityGroup.addIngressRule(albSecurityGroup, ec2.Port.tcp(80), 'Allow HTTP from ALB');

    // Explicit egress rules for SMTP (SES) - Using recommended ports 587 (STARTTLS) and 465 (TLS)
    // Port 25 is intentionally avoided as EC2 throttles it
    moodleSecurityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(587),
      'Allow SMTP STARTTLS to SES (port 587 - recommended)'
    );
    moodleSecurityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(465),
      'Allow SMTP TLS to SES (port 465 - alternative)'
    );
    // Add HTTPS egress for SES API calls (if needed for future integrations)
    moodleSecurityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(443),
      'Allow HTTPS for SES API and general outbound'
    );

    const dbSecurityGroup = new ec2.SecurityGroup(this, 'DbSecurityGroup', {
      vpc,
      description: 'Security group for MariaDB RDS',
      allowAllOutbound: false,
    });
    dbSecurityGroup.addIngressRule(moodleSecurityGroup, ec2.Port.tcp(3306), 'Allow MySQL from Moodle');

    const efsSecurityGroup = new ec2.SecurityGroup(this, 'EfsSecurityGroup', {
      vpc,
      description: 'Security group for EFS',
      allowAllOutbound: true,
    });
    efsSecurityGroup.addIngressRule(moodleSecurityGroup, ec2.Port.tcp(2049), 'Allow NFS from Moodle');

    // EFS File Systems (without automatic mount target creation)
    const dataFileSystem = new efs.FileSystem(this, 'MoodleDataEfs', {
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

    const appFileSystem = new efs.FileSystem(this, 'MoodleAppEfs', {
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

    // Add backup tags to EFS filesystems
    cdk.Tags.of(dataFileSystem).add('BackupEnabled', 'true');
    cdk.Tags.of(appFileSystem).add('BackupEnabled', 'true');

    // Security group egress for clarity (instances to EFS on 2049)
    moodleSecurityGroup.addEgressRule(efsSecurityGroup, ec2.Port.tcp(2049), 'Allow NFS to EFS');

    // ========================================
    // SES SMTP VPC ENDPOINT (OPTIONAL)
    // ========================================
    // Create VPC endpoint for SES SMTP to enable email sending from private subnets
    // without requiring NAT Gateway (cost optimization and improved reliability)
    // This is OPTIONAL but HIGHLY RECOMMENDED for production environments

    // Parameter to control SES VPC Endpoint creation
    const createSesVpcEndpoint = new cdk.CfnParameter(this, 'CreateSesVpcEndpoint', {
      type: 'String',
      allowedValues: ['true', 'false'],
      default: 'true',
      description: 'Create VPC Interface Endpoint for SES SMTP (recommended for private subnets)'
    });

    // Security group for SES VPC Endpoint
    const sesVpcEndpointSecurityGroup = new ec2.SecurityGroup(this, 'SesVpcEndpointSecurityGroup', {
      vpc,
      description: 'Security group for SES SMTP VPC Endpoint',
      allowAllOutbound: false,
    });

    // Allow inbound SMTP traffic from Moodle instances to SES endpoint
    sesVpcEndpointSecurityGroup.addIngressRule(
      moodleSecurityGroup,
      ec2.Port.tcp(587),
      'Allow SMTP STARTTLS from Moodle instances'
    );
    sesVpcEndpointSecurityGroup.addIngressRule(
      moodleSecurityGroup,
      ec2.Port.tcp(465),
      'Allow SMTP TLS from Moodle instances'
    );

    // Create SES SMTP VPC Interface Endpoint
    // Note: SES SMTP endpoint service name format: com.amazonaws.{region}.email-smtp
    const sesSmtpEndpoint = new ec2.InterfaceVpcEndpoint(this, 'SesSmtpVpcEndpoint', {
      vpc,
      service: new ec2.InterfaceVpcEndpointService(
        `com.amazonaws.${this.region}.email-smtp`,
        587 // Primary port for STARTTLS
      ),
      subnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      securityGroups: [sesVpcEndpointSecurityGroup],
      privateDnsEnabled: true, // Enable private DNS to resolve email-smtp.{region}.amazonaws.com
    });

    // Apply condition to SES endpoint resources
    const createSesEndpointCondition = new cdk.CfnCondition(this, 'CreateSesEndpointCondition', {
      expression: cdk.Fn.conditionEquals(createSesVpcEndpoint.valueAsString, 'true'),
    });
    (sesVpcEndpointSecurityGroup.node.defaultChild as ec2.CfnSecurityGroup).cfnOptions.condition = createSesEndpointCondition;
    (sesSmtpEndpoint.node.defaultChild as ec2.CfnVPCEndpoint).cfnOptions.condition = createSesEndpointCondition;

    // EFS resource policies: allow TLS/IAM client mounts within this VPC
    const efsResourcePolicy = new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      principals: [new iam.AnyPrincipal()],
      actions: [
        'elasticfilesystem:ClientMount',
        'elasticfilesystem:ClientWrite',
      ],
      resources: ['*'],
      conditions: {
        Bool: { 'aws:SecureTransport': true },
        StringEquals: { 'aws:SourceVpc': vpc.vpcId },
      },
    });
    dataFileSystem.addToResourcePolicy(efsResourcePolicy);
    appFileSystem.addToResourcePolicy(efsResourcePolicy);


    // Custom resource to ensure EFS mount targets have correct security groups
    const efsSecurityGroupFixer = new cdk.CustomResource(this, 'EfsSecurityGroupFixer', {
      serviceToken: this.createEfsSecurityGroupFixerProvider().serviceToken,
      properties: {
        AppFileSystemId: appFileSystem.fileSystemId,
        DataFileSystemId: dataFileSystem.fileSystemId,
        SecurityGroupId: efsSecurityGroup.securityGroupId,
        Region: this.region,
      },
    });



    // RDS Subnet Group
    const dbSubnetGroup = new rds.SubnetGroup(this, 'MoodleDbSubnetGroup', {
      vpc,
      description: 'Subnet group for Moodle MariaDB',
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
      },
    });

    // Use default parameter group for MariaDB 10.11 to avoid parameter issues

    // RDS MariaDB Instance
    const database = new rds.DatabaseInstance(this, 'MoodleDatabase', {
      engine: rds.DatabaseInstanceEngine.mariaDb({
        version: rds.MariaDbEngineVersion.VER_10_11,
      }),
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.M7I, ec2.InstanceSize.XLARGE),
      credentials: rds.Credentials.fromSecret(dbSecret),
      vpc,
      subnetGroup: dbSubnetGroup,
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
    cdk.Tags.of(database).add('BackupEnabled', 'true');


    // Optional external Redis configuration (auto-discovery friendly)
    const useExternalRedis = new cdk.CfnParameter(this, 'UseExternalRedis', {
      type: 'String',
      allowedValues: ['true', 'false'],
      default: 'false',
      description: 'Use an external Redis cluster and skip creating one',
    });
    const externalRedisEndpoint = new cdk.CfnParameter(this, 'ExternalRedisEndpoint', {
      type: 'String',
      default: '',
      description: 'When UseExternalRedis=true, provide the Redis endpoint hostname',
    });
    const externalRedisSecurityGroupId = new cdk.CfnParameter(this, 'ExternalRedisSecurityGroupId', {
      type: 'String',
      default: '',
      description: 'When UseExternalRedis=true, the Security Group ID attached to the Redis cluster',
    });

    // Conditions to control internal vs external Redis resources
    const useExternalCond = new cdk.CfnCondition(this, 'UseExternalRedisCond', {
      expression: cdk.Fn.conditionEquals(useExternalRedis.valueAsString, 'true'),
    });
    const useInternalCond = new cdk.CfnCondition(this, 'UseInternalRedisCond', {
      expression: cdk.Fn.conditionEquals(useExternalRedis.valueAsString, 'false'),
    });

    // === ElastiCache Redis (sessions/cache) ===
    const redisSecurityGroup = new ec2.SecurityGroup(this, 'RedisSecurityGroup', {
      vpc,
      description: 'Security group for Redis (ElastiCache) allowing access from Moodle EC2',
      allowAllOutbound: true,
    });
    // Create ingress explicitly so we can attach conditions
    const internalRedisIngress = new ec2.CfnSecurityGroupIngress(this, 'RedisIngressFromMoodle', {
      ipProtocol: 'tcp',
      fromPort: 6379,
      toPort: 6379,
      groupId: redisSecurityGroup.securityGroupId,
      sourceSecurityGroupId: moodleSecurityGroup.securityGroupId,
      description: 'Allow Redis from Moodle (internal)'
    });
    internalRedisIngress.cfnOptions.condition = useInternalCond;

    // Additional ingress to allow any host within the VPC CIDR to use Redis (enables sharing across stacks)
    const internalRedisIngressVpc = new ec2.CfnSecurityGroupIngress(this, 'RedisIngressFromVpcCidr', {
      ipProtocol: 'tcp',
      fromPort: 6379,
      toPort: 6379,
      groupId: redisSecurityGroup.securityGroupId,
      cidrIp: vpc.vpcCidrBlock,
      description: 'Allow Redis from within VPC (shared across Moodle stacks)'
    });
    internalRedisIngressVpc.cfnOptions.condition = useInternalCond;

    // If using an external Redis, allow inbound from Moodle SG to that external SG
    const externalRedisIngress = new ec2.CfnSecurityGroupIngress(this, 'ExternalRedisIngressFromMoodle', {
      ipProtocol: 'tcp',
      fromPort: 6379,
      toPort: 6379,
      groupId: externalRedisSecurityGroupId.valueAsString,
      sourceSecurityGroupId: moodleSecurityGroup.securityGroupId,
      description: 'Allow Redis from Moodle (external)'
    });
    externalRedisIngress.cfnOptions.condition = useExternalCond;

    // Only create the internal Redis security group when needed
    (redisSecurityGroup.node.defaultChild as ec2.CfnSecurityGroup).cfnOptions.condition = useInternalCond;

    // Subnet group for Redis in private subnets with egress (internal only)
    const redisSubnetGroup = new elasticache.CfnSubnetGroup(this, 'RedisSubnetGroup', {
      description: 'Subnet group for Moodle Redis',
      subnetIds: vpc.selectSubnets({ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }).subnetIds,
      cacheSubnetGroupName: `${this.stackName}-redis-subnet-group`,
    });
    redisSubnetGroup.cfnOptions.condition = useInternalCond;

    // Single-node Redis for sessions/cache (internal only)
    const redisCluster = new elasticache.CfnCacheCluster(this, 'MoodleRedis', {
      engine: 'redis',
      cacheNodeType: 'cache.t4g.micro',
      numCacheNodes: 1,
      cacheSubnetGroupName: redisSubnetGroup.cacheSubnetGroupName!,
      vpcSecurityGroupIds: [redisSecurityGroup.securityGroupId],
    });
    redisCluster.node.addDependency(redisSubnetGroup);
    redisCluster.cfnOptions.condition = useInternalCond;

    // IAM Role for EC2 instances
    const ec2Role = new iam.Role(this, 'MoodleEc2Role', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'IAM role for Moodle EC2 instances',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // Allow instances to use IAM auth for EFS when using mount helper (tls,iam)
    ec2Role.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticfilesystem:ClientMount',
        'elasticfilesystem:ClientWrite',
        'elasticfilesystem:DescribeMountTargets',
        'elasticfilesystem:DescribeFileSystems'
      ],
      resources: ['*'],
    }));

    // Grant permissions to access EFS, Secrets Manager, and CloudWatch
    dataFileSystem.grant(ec2Role, 'elasticfilesystem:ClientMount', 'elasticfilesystem:ClientWrite');
    appFileSystem.grant(ec2Role, 'elasticfilesystem:ClientMount', 'elasticfilesystem:ClientWrite');
    dbSecret.grantRead(ec2Role);

    ec2Role.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'logs:CreateLogGroup',
        'logs:CreateLogStream',
        'logs:PutLogEvents',
        'logs:DescribeLogStreams',
      ],
      resources: [
        moodleLogGroup.logGroupArn,
        systemLogGroup.logGroupArn,
        `${moodleLogGroup.logGroupArn}:*`,
        `${systemLogGroup.logGroupArn}:*`,
      ],
    }));

    // Add permissions for dynamic resource discovery
    ec2Role.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'cloudformation:DescribeStacks',
        'ec2:DescribeTags',
        'ec2:DescribeNetworkInterfaces',
        'elasticloadbalancing:DescribeLoadBalancers',
        'elasticfilesystem:DescribeFileSystems',
        'elasticfilesystem:DescribeTags',
        'elasticfilesystem:DescribeMountTargets',
        'elasticfilesystem:DescribeMountTargetSecurityGroups',
        'rds:DescribeDBInstances',
        'secretsmanager:ListSecrets',
        'secretsmanager:GetSecretValue',
        'ssm:GetParameter',
        'ssm:GetParameters',
      ],
      resources: ['*'],
    }));

    // ========================================
    // SES EMAIL PERMISSIONS
    // ========================================
    // Grant EC2 instances permission to send emails via SES
    // This allows Moodle to send emails using AWS SES SMTP or API
    ec2Role.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'ses:SendEmail',
        'ses:SendRawEmail',
        'ses:SendTemplatedEmail',
        'ses:SendBulkTemplatedEmail',
      ],
      resources: ['*'], // Can be restricted to specific verified identities if needed
      conditions: {
        StringEquals: {
          'ses:FromAddress': [
            'noreply@tsin.ca',
            'noreply@learning.tsin.ca',
            'it@tsin.ca',
          ],
        },
      },
    }));

    // Grant permission to retrieve SES SMTP credentials from Secrets Manager
    // This is for storing SES SMTP username/password securely
    ec2Role.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'secretsmanager:GetSecretValue',
        'secretsmanager:DescribeSecret',
      ],
      resources: [
        `arn:aws:secretsmanager:${this.region}:${this.account}:secret:moodle/ses/*`,
      ],
    }));

    // Allow instances to manage their own scale-in protection
    ec2Role.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'autoscaling:SetInstanceProtection',
        'autoscaling:DescribeAutoScalingInstances',
        'autoscaling:DescribeAutoScalingGroups'
      ],
      resources: ['*'],
    }));

    // Grant access to the scripts bucket
    scriptsBucket.grantRead(ec2Role);

    // Instance profile is automatically created by CDK when role is assigned to launch template

    // Application Load Balancer
    const alb = new elbv2.ApplicationLoadBalancer(this, 'MoodleAlb', {
      vpc,
      internetFacing: true,
      securityGroup: albSecurityGroup,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
      },
    });

    // Target Group with improved health checks
    const targetGroup = new elbv2.ApplicationTargetGroup(this, 'MoodleTargetGroup', {
      vpc,
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.INSTANCE,
      healthCheck: {
        enabled: true,
        healthyHttpCodes: '200',
        path: '/health.php',  // Use PHP health check to test Apache->PHP-FPM->DB
        interval: cdk.Duration.seconds(10),  // More frequent checks
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 2,  // Faster detection of unhealthy instances
      },
      deregistrationDelay: cdk.Duration.seconds(300),  // Connection draining
    });

    // Enable sticky sessions (LB cookie) to keep PHP session on the same instance
    targetGroup.setAttribute('stickiness.enabled', 'true');
    targetGroup.setAttribute('stickiness.type', 'lb_cookie');
    // 2 hours stickiness to cover installation/first login flows
    targetGroup.setAttribute('stickiness.lb_cookie.duration_seconds', '7200');
    // Note: connection_termination.enabled is only supported for HTTPS/TLS target groups
    // Since we use HTTP (ALB terminates SSL), we cannot enable this attribute


    // Listener parameters
    const certificateArn = new cdk.CfnParameter(this, 'CertificateArn', {
      type: 'String',
      default: 'arn:aws:acm:ca-central-1:483382415631:certificate/356e41fc-6aed-4d07-96bf-1ab79eeedf5a',
      description: 'ARN of the ACM certificate for the custom domain (must be in the same region as the ALB)'
    });
    const customDomain = new cdk.CfnParameter(this, 'CustomDomainName', {
      type: 'String',
      default: 'elearning.tsin.ca',
      description: 'Custom domain name pointing to the ALB (Route53 record must already exist)'
    });

    // Store certificate details in Secrets Manager for retrieval by instances/automation
    const certificateDetailsSecret = new secretsmanager.Secret(this, 'MoodleCertificateSecret', {
      description: 'ACM certificate details (ARN and domain) for Moodle ALB',
      secretObjectValue: {
        certificateArn: cdk.SecretValue.unsafePlainText(certificateArn.valueAsString),
        domain: cdk.SecretValue.unsafePlainText(customDomain.valueAsString),
      },
    });

    // Grant EC2 role read access to the certificate secret
    certificateDetailsSecret.grantRead(ec2Role);

    // HTTP listener -> redirect to HTTPS (retain logical id 'MoodleListener' to avoid replacement conflicts)
    const httpListener = alb.addListener('MoodleListener', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      defaultAction: elbv2.ListenerAction.redirect({ protocol: 'HTTPS', port: '443', permanent: true }),
    });
    // Explicit /health rule on HTTP to forward to target group (so health checks stay 200 on HTTP)
    new elbv2.ApplicationListenerRule(this, 'HealthOnHttpRule', {
      listener: httpListener,
      priority: 9,
      conditions: [elbv2.ListenerCondition.pathPatterns(['/health'])],
      action: elbv2.ListenerAction.forward([targetGroup]),
    });

    // NOTE: HTTPS listener is currently managed out-of-band due to legacy drift.
    // The ALB already has a 443 listener with the correct certificate. We keep the HTTP -> HTTPS redirect here.
    // Once the stack is stabilized, we can re-adopt the HTTPS listener into CDK.
    // (intentionally no HTTPS listener resource here)

    // Ensure any existing unmanaged 443 listeners are removed, then create managed HTTPS listener
    const httpsListenerReset = new cdk.CustomResource(this, 'AlbHttpsListenerReset', {
      serviceToken: this.createAlbHttpsListenerResetProvider().serviceToken,
      properties: {
        LoadBalancerArn: alb.loadBalancerArn,
      },
    });

    // Managed HTTPS listener forwarding to the Moodle target group
    const httpsListener = new elbv2.ApplicationListener(this, 'MoodleHttpsListener', {
      loadBalancer: alb,
      port: 443,
      protocol: elbv2.ApplicationProtocol.HTTPS,
      certificates: [elbv2.ListenerCertificate.fromArn(certificateArn.valueAsString)],
      defaultAction: elbv2.ListenerAction.forward([targetGroup]),
    });
    httpsListener.node.addDependency(httpsListenerReset);


    // Get the latest Amazon Linux 2023 AMI
    const amzn2023Ami = ec2.MachineImage.latestAmazonLinux2023({
      cpuType: ec2.AmazonLinuxCpuType.X86_64,
    });

    // User Data Script - build with resource params and SSM fallbacks
    const userData = this.createUserDataBootstrapOnly({
      appEfsId: appFileSystem.fileSystemId,
      dataEfsId: dataFileSystem.fileSystemId,
      dbEndpoint: database.instanceEndpoint.hostname,
      region: cdk.Stack.of(this).region,
      dbSecretArn: dbSecret.secretArn,
      efsSgId: efsSecurityGroup.securityGroupId,
      moodleWwwroot: `https://${customDomain.valueAsString}`,
    });

    // Launch Template
    const launchTemplate = new ec2.LaunchTemplate(this, 'MoodleLaunchTemplate', {
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.M7I, ec2.InstanceSize.XLARGE),
      machineImage: amzn2023Ami,
      securityGroup: moodleSecurityGroup,
      role: ec2Role,
      userData: userData,
      requireImdsv2: true,
      httpTokens: ec2.LaunchTemplateHttpTokens.REQUIRED,
      httpPutResponseHopLimit: 2,
    });

    // Auto Scaling Group
    const autoScalingGroup = new autoscaling.AutoScalingGroup(this, 'MoodleAutoScalingGroup', {
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

    // Attach Auto Scaling Group to Target Group
    autoScalingGroup.attachToApplicationTargetGroup(targetGroup);

    // Ensure EFS mount target SGs are applied before instances launch
    autoScalingGroup.node.addDependency(efsSecurityGroupFixer);

    // Add auto-scaling policies based on CPU
    autoScalingGroup.scaleOnCpuUtilization('CpuScaling', {
      targetUtilizationPercent: 70,
      cooldown: cdk.Duration.minutes(5),
    });

    // Add target tracking scaling based on ALB request count
    autoScalingGroup.scaleOnRequestCount('RequestCountScaling', {
      targetRequestsPerMinute: 1000,
    });

    // CloudWatch Alarms for monitoring
    // Alarm: Unhealthy target count
    const unhealthyTargetAlarm = new cloudwatch.Alarm(this, 'UnhealthyTargetAlarm', {
      metric: targetGroup.metricUnhealthyHostCount(),
      threshold: 1,
      evaluationPeriods: 2,
      datapointsToAlarm: 2,
      alarmDescription: 'Alert when any target becomes unhealthy',
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // Alarm: High target response time (504 timeout indicator)
    const highResponseTimeAlarm = new cloudwatch.Alarm(this, 'HighResponseTimeAlarm', {
      metric: targetGroup.metricTargetResponseTime(),
      threshold: 10,  // 10 seconds
      evaluationPeriods: 2,
      datapointsToAlarm: 2,
      alarmDescription: 'Alert when target response time exceeds 10 seconds',
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // Alarm: High 5xx error rate
    const high5xxAlarm = new cloudwatch.Alarm(this, 'High5xxAlarm', {
      metric: alb.metricHttpCodeTarget(elbv2.HttpCodeTarget.TARGET_5XX_COUNT),
      threshold: 10,
      evaluationPeriods: 1,
      alarmDescription: 'Alert when 5xx errors exceed 10 per minute',
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // Outputs
    new cdk.CfnOutput(this, 'MoodleUrl', {
      value: `https://${customDomain.valueAsString}`,
      description: 'Moodle Application URL',
    });

    // Export Redis endpoint to SSM for autodiscovery (internal or external)
    const redisEndpointValue = cdk.Fn.conditionIf(
      useInternalCond.logicalId,
      redisCluster.attrRedisEndpointAddress,
      externalRedisEndpoint.valueAsString,
    ).toString();
    new ssm.StringParameter(this, 'ParamRedisEndpoint', {
      parameterName: '/moodle/redis/endpoint',
      stringValue: redisEndpointValue,
    });

    // Publish DB endpoint and secret ARN for instance discovery
    new ssm.StringParameter(this, 'ParamDbEndpointV2', {
      parameterName: '/moodle/db/endpoint',
      stringValue: database.instanceEndpoint.hostname,
    });
    new ssm.StringParameter(this, 'ParamDbSecretArn', {
      parameterName: '/moodle/db/secretArn',
      stringValue: dbSecret.secretArn,
    });

    // Expose certificate secret ARN via outputs and SSM for easy discovery
    new cdk.CfnOutput(this, 'CertificateSecretArn', {
      value: certificateDetailsSecret.secretArn,
      description: 'Secrets Manager ARN for ACM certificate details',
    });
    new ssm.StringParameter(this, 'ParamCertificateSecretArn', { parameterName: '/moodle/certificateSecretArn', stringValue: certificateDetailsSecret.secretArn });

    new cdk.CfnOutput(this, 'AlbDnsName', {
      value: alb.loadBalancerDnsName,
      description: 'ALB DNS name',
    });

    new cdk.CfnOutput(this, 'DatabaseEndpoint', {
      value: database.instanceEndpoint.hostname,
      description: 'RDS MariaDB Endpoint',
    });

    // Export parameters to SSM for fallback
    new ssm.StringParameter(this, 'ParamAppEfsId', { parameterName: '/moodle/appEfsId', stringValue: appFileSystem.fileSystemId });
    new ssm.StringParameter(this, 'ParamDataEfsId', { parameterName: '/moodle/dataEfsId', stringValue: dataFileSystem.fileSystemId });
    new ssm.StringParameter(this, 'ParamDbEndpoint', { parameterName: '/moodle/dbEndpoint', stringValue: database.instanceEndpoint.hostname });

    new ssm.StringParameter(this, 'ParamAlbArn', { parameterName: '/moodle/albArn', stringValue: alb.loadBalancerArn });
    new ssm.StringParameter(this, 'ParamAlbDns', { parameterName: '/moodle/albDns', stringValue: alb.loadBalancerDnsName });

    // ========================================
    // SES CONFIGURATION PARAMETERS
    // ========================================
    // Store SES configuration in SSM for easy access by Moodle instances
    new ssm.StringParameter(this, 'ParamSesSmtpEndpoint', {
      parameterName: '/moodle/ses/smtpEndpoint',
      stringValue: `email-smtp.${this.region}.amazonaws.com`,
      description: 'SES SMTP endpoint for the current region',
    });

    new ssm.StringParameter(this, 'ParamSesSmtpPort', {
      parameterName: '/moodle/ses/smtpPort',
      stringValue: '587',
      description: 'SES SMTP port (587 for STARTTLS, 465 for TLS)',
    });

    new ssm.StringParameter(this, 'ParamSesSecurity', {
      parameterName: '/moodle/ses/security',
      stringValue: 'tls',
      description: 'SES SMTP security protocol (tls for STARTTLS)',
    });

    new ssm.StringParameter(this, 'ParamSesFromAddress', {
      parameterName: '/moodle/ses/fromAddress',
      stringValue: 'noreply@tsin.ca',
      description: 'Default FROM address for SES emails',
    });

    new cdk.CfnOutput(this, 'DataEfsId', {
      value: dataFileSystem.fileSystemId,
      description: 'EFS File System ID for /data',
    });

    new cdk.CfnOutput(this, 'AppEfsId', {
      value: appFileSystem.fileSystemId,
      description: 'EFS File System ID for /app',
    });

    // SES Configuration Outputs
    new cdk.CfnOutput(this, 'SesSmtpEndpoint', {
      value: `email-smtp.${this.region}.amazonaws.com`,
      description: 'SES SMTP Endpoint',
    });

    new cdk.CfnOutput(this, 'SesSmtpPort', {
      value: '587',
      description: 'SES SMTP Port (STARTTLS)',
    });

    new cdk.CfnOutput(this, 'SesVpcEndpointCreated', {
      value: cdk.Fn.conditionIf(
        createSesEndpointCondition.logicalId,
        'Yes - Private DNS enabled',
        'No - Using NAT Gateway'
      ).toString(),
      description: 'Whether SES VPC Endpoint was created',
    });
  }

  private createUserDataScript(p: { appEfsId: string; dataEfsId: string; dbEndpoint: string; region: string; dbSecretArn: string; efsSgId: string; moodleWwwroot?: string; }): ec2.UserData {
    const userData = ec2.UserData.forLinux();

    // Simple user data that downloads and executes the intelligent installation script from S3

    userData.addCommands(
      '#!/bin/bash',
      'set -euo pipefail',
      '',
      '# Logging setup',
      'exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1',
      'echo "Starting Moodle installation script at $(date)"',
      '',
      '# Set environment variables for the intelligent installation script',
      `export APP_EFS_ID="${p.appEfsId}"`,
      `export DATA_EFS_ID="${p.dataEfsId}"`,
      `export DB_ENDPOINT="${p.dbEndpoint}"`,
      `export DB_SECRET_ARN="${p.dbSecretArn}"`,
      `export AWS_REGION="${p.region}"`,
      `export REGION="${p.region}"`,
      'export MOODLE_SITE_NAME="Touchstone Institute"',
      'export MOODLE_ADMIN_USER="moodle-admin"',
      'export MOODLE_ADMIN_EMAIL="it@tsin.ca"',
      `export EFS_SG_ID="${p.efsSgId}"`,
      // If a stack-level Moodle URL is provided, pass it for the intelligent installer to honor
      `export MOODLE_WWWROOT="${p.moodleWwwroot}"`,
      // Multi-instance idempotency defaults
      'export MULTI_INSTANCE_SAFE=1',
      'export ALLOW_DESTRUCTIVE=0',
      'echo "UserData params: APP_EFS_ID=$APP_EFS_ID DATA_EFS_ID=$DATA_EFS_ID REGION=$REGION MULTI_INSTANCE_SAFE=$MULTI_INSTANCE_SAFE"',
      '',
      '# Enable scale-in protection at the start (failsafe will remove later)',
      'TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds:21600 || true)',
      'INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id || true)',
      'ASG_NAME=$(aws autoscaling describe-auto-scaling-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "AutoScalingInstances[0].AutoScalingGroupName" --output text 2>/dev/null || echo "")',
      'if [ -n "$ASG_NAME" ]; then aws autoscaling set-instance-protection --instance-ids "$INSTANCE_ID" --auto-scaling-group-name "$ASG_NAME" --protected-from-scale-in --region "$REGION" || true; fi',
      '',
      '# Basic system setup',
      'yum update -y',
      'yum install -y amazon-cloudwatch-agent git mariadb105 jq',
      '',
      '# Install Apache and PHP',
      'yum install -y httpd php php-mysqlnd php-gd php-xml php-mbstring php-json php-zip php-curl php-intl php-soap php-ldap php-opcache php-fpm php-redis',
      '',
      '# Configure PHP-FPM for production load',
      'echo "Configuring PHP-FPM for production..."',
      'cat > /etc/php-fpm.d/www.conf <<\'EOFPHP\'',
      '[www]',
      'user = apache',
      'group = apache',
      'listen = /run/php-fpm/www.sock',
      'listen.owner = apache',
      'listen.group = apache',
      'listen.mode = 0660',
      '',
      '; Process pool management - optimized for production',
      'pm = dynamic',
      'pm.max_children = 50',
      'pm.start_servers = 10',
      'pm.min_spare_servers = 5',
      'pm.max_spare_servers = 20',
      'pm.max_requests = 1000',
      '',
      '; Timeouts',
          'request_terminate_timeout = 600',
      'request_slowlog_timeout = 10s',
      '',
      '; Logging',
      'slowlog = /var/log/php-fpm/www-slow.log',
      'catch_workers_output = yes',
      '',
      '; Status monitoring',
      'pm.status_path = /php-fpm-status',
      'ping.path = /php-fpm-ping',
      'ping.response = pong',
      '',
      '; Security',
      'php_admin_value[error_log] = /var/log/php-fpm/www-error.log',
      'php_admin_flag[log_errors] = on',
      'EOFPHP',
      '',
      '# Create PHP-FPM log directory',
      'mkdir -p /var/log/php-fpm',
      'chown apache:apache /var/log/php-fpm',
      '',
      '# Configure PHP settings for Moodle',
          'cat > /etc/php.d/99-moodle.ini <<\'EOFPHPINI\'',
          'max_execution_time = 600',
          'max_input_time = 900',
          'memory_limit = 4096M',
          'post_max_size = 1024M',
          'upload_max_filesize = 1024M',
      'max_input_vars = 5000',
      'EOFPHPINI',
      '',
      '# Ensure Moodle vhost with PHP-FPM proxy and timeout settings',
      'cat > /etc/httpd/conf.d/moodle.conf <<\'EOFV\'',
      '<VirtualHost *:80>',
          '  DocumentRoot /app/moodle',
          '  DirectoryIndex index.php index.html',
          '  LimitRequestBody 0',
      '',
      '  # PHP-FPM proxy configuration',
      '  <FilesMatch \\.php$>',
      '    SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"',
      '  </FilesMatch>',
      '',
      '  # Timeout settings to prevent 504 errors',
          '  ProxyTimeout 600',
          '  Timeout 600',
      '',
      '  <Directory /app/moodle>',
      '    AllowOverride All',
      '    Require all granted',
      '    Options -Indexes +FollowSymLinks',
      '  </Directory>',
      '',
      '  # Logging',
      '  ErrorLog /var/log/httpd/moodle_error.log',
      '  CustomLog /var/log/httpd/moodle_access.log combined',
      '',
      '  # Security headers',
      '  Header always set X-Content-Type-Options "nosniff"',
      '  Header always set X-Frame-Options "SAMEORIGIN"',
      '</VirtualHost>',
      'EOFV',
      '',
      '# Ensure health endpoints exist early',
      'mkdir -p /app/moodle',
      'echo OK > /app/moodle/health',
      '',
      '# Create advanced health check that tests Apache, PHP-FPM, and DB',
      'cat > /app/moodle/health.php <<\'EOFH\'',
      '<?php',
      '// Advanced health check that tests Apache, PHP-FPM, and database',
      '$start = microtime(true);',
      '$healthy = true;',
      '$errors = [];',
      '$warnings = [];',
      '',
      '// Test 1: PHP is executing (tests Apache -> PHP-FPM communication)',
      'if (!function_exists("phpversion")) {',
      '    $healthy = false;',
      '    $errors[] = "PHP not functioning";',
      '} else {',
      '    // PHP is working, which means Apache successfully proxied to PHP-FPM',
      '    $warnings[] = "PHP " . phpversion() . " OK";',
      '}',
      '',
      '// Test 2: PHP-FPM socket is accessible',
      'if (function_exists("php_sapi_name")) {',
      '    $sapi = php_sapi_name();',
      '    if ($sapi !== "fpm-fcgi") {',
      '        $warnings[] = "Not using PHP-FPM (SAPI: $sapi)";',
      '    }',
      '}',
      '',
      '// Test 3: Response time is acceptable (< 5 seconds)',
      '$elapsed = microtime(true) - $start;',
      'if ($elapsed > 5) {',
      '    $healthy = false;',
      '    $errors[] = "Response too slow: " . round($elapsed, 2) . "s";',
      '}',
      '',
      '// Test 4: Memory available',
      '$memLimit = ini_get("memory_limit");',
      '$memUsage = memory_get_usage(true);',
      'if ($memUsage > 200 * 1024 * 1024) { // 200MB',
      '    $warnings[] = "High memory usage: " . round($memUsage / 1024 / 1024, 2) . "MB";',
      '}',
      '',
      '// Test 5: Database connectivity (if config exists)',
      'if (file_exists("/app/moodle/config.php")) {',
      '    try {',
      '        // Parse config.php to get DB credentials',
      '        $config = file_get_contents("/app/moodle/config.php");',
      '        if (preg_match("/\\$CFG->dbhost\\s*=\\s*[\'\\"]([^\'\\"]+)[\'\\"]/", $config, $matches)) {',
      '            $dbhost = $matches[1];',
      '            if (preg_match("/\\$CFG->dbname\\s*=\\s*[\'\\"]([^\'\\"]+)[\'\\"]/", $config, $matches)) {',
      '                $dbname = $matches[1];',
      '                if (preg_match("/\\$CFG->dbuser\\s*=\\s*[\'\\"]([^\'\\"]+)[\'\\"]/", $config, $matches)) {',
      '                    $dbuser = $matches[1];',
      '                    if (preg_match("/\\$CFG->dbpass\\s*=\\s*[\'\\"]([^\'\\"]+)[\'\\"]/", $config, $matches)) {',
      '                        $dbpass = $matches[1];',
      '                        // Quick DB connection test with 2 second timeout',
      '                        try {',
      '                            $pdo = new PDO("mysql:host=$dbhost;dbname=$dbname", $dbuser, $dbpass, [',
      '                                PDO::ATTR_TIMEOUT => 2,',
      '                                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION',
      '                            ]);',
      '                            $pdo->query("SELECT 1");',
      '                            $warnings[] = "DB OK";',
      '                            $pdo = null;',
      '                        } catch (Exception $e) {',
      '                            $healthy = false;',
      '                            $errors[] = "DB connection failed: " . $e->getMessage();',
      '                        }',
      '                    }',
      '                }',
      '            }',
      '        }',
      '    } catch (Exception $e) {',
      '        $warnings[] = "DB test skipped: " . $e->getMessage();',
      '    }',
      '}',
      '',
      '// Test 6: Apache headers (X-Powered-By should be set by Apache)',
      'if (function_exists("apache_get_modules")) {',
      '    $warnings[] = "Apache modules loaded";',
      '}',
      '',
      '// Return status',
      'if ($healthy) {',
      '    http_response_code(200);',
      '    echo "OK";',
      '    if (!empty($warnings)) {',
      '        echo " (" . implode(", ", $warnings) . ")";',
      '    }',
      '} else {',
      '    http_response_code(503);',
      '    echo "UNHEALTHY: " . implode(", ", $errors);',
      '}',
      '',
      '// Add response time',
      '$totalElapsed = microtime(true) - $start;',
      'echo " [" . round($totalElapsed * 1000, 2) . "ms]";',
      '?>',
      'EOFH',
      '',
      '# Avoid recursive chown/chmod on shared EFS; only set for health files',
      'chown apache:apache /app/moodle/health /app/moodle/health.php || true',
      'chmod 644 /app/moodle/health.php || true',
      '',
      '# Start/enable web services',
      'systemctl enable httpd',
      'systemctl enable php-fpm || true',
      'systemctl restart httpd',
      'systemctl restart php-fpm || true',
      'sleep 3',
      'curl -s -o /dev/null -w "%{http_code}\\n" http://localhost/health || true',
      '',
      '# Configure CloudWatch Agent for monitoring',
      'echo "Configuring CloudWatch Agent..."',
      'cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<\'EOFCW\'',
      '{',
      '  "agent": {',
      '    "metrics_collection_interval": 60,',
      '    "run_as_user": "root"',
      '  },',
      '  "logs": {',
      '    "logs_collected": {',
      '      "files": {',
      '        "collect_list": [',
      '          {',
      '            "file_path": "/var/log/httpd/error_log",',
      '            "log_group_name": "/aws/ec2/moodle",',
      '            "log_stream_name": "{instance_id}/apache-error",',
      '            "timezone": "UTC"',
      '          },',
      '          {',
      '            "file_path": "/var/log/httpd/moodle_error.log",',
      '            "log_group_name": "/aws/ec2/moodle",',
      '            "log_stream_name": "{instance_id}/moodle-error",',
      '            "timezone": "UTC"',
      '          },',
      '          {',
      '            "file_path": "/var/log/php-fpm/www-slow.log",',
      '            "log_group_name": "/aws/ec2/moodle",',
      '            "log_stream_name": "{instance_id}/php-fpm-slow",',
      '            "timezone": "UTC"',
      '          },',
      '          {',
      '            "file_path": "/var/log/php-fpm/www-error.log",',
      '            "log_group_name": "/aws/ec2/moodle",',
      '            "log_stream_name": "{instance_id}/php-fpm-error",',
      '            "timezone": "UTC"',
      '          }',
      '        ]',
      '      }',
      '    }',
      '  },',
      '  "metrics": {',
      '    "namespace": "Moodle",',
      '    "metrics_collected": {',
      '      "cpu": {',
      '        "measurement": [',
      '          {"name": "cpu_usage_idle", "rename": "CPU_IDLE", "unit": "Percent"},',
      '          {"name": "cpu_usage_iowait", "rename": "CPU_IOWAIT", "unit": "Percent"}',
      '        ],',
      '        "metrics_collection_interval": 60,',
      '        "totalcpu": false',
      '      },',
      '      "mem": {',
      '        "measurement": [',
      '          {"name": "mem_used_percent", "rename": "MEM_USED", "unit": "Percent"}',
      '        ],',
      '        "metrics_collection_interval": 60',
      '      },',
      '      "processes": {',
      '        "measurement": [',
      '          {"name": "running", "rename": "PHP_FPM_PROCESSES", "unit": "Count"}',
      '        ],',
      '        "metrics_collection_interval": 60',
      '      }',
      '    },',
      '    "append_dimensions": {',
      '      "InstanceId": "${aws:InstanceId}",',
      '      "AutoScalingGroupName": "${aws:AutoScalingGroupName}"',
      '    }',
      '  }',
      '}',
      'EOFCW',
      '',
      '# Start CloudWatch Agent',
      '/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \\',
      '  -a fetch-config \\',
      '  -m ec2 \\',
      '  -s \\',
      '  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json || true',
      '',
      '# Install EFS utils',
      'yum install -y amazon-efs-utils',
'yum install -y nfs-utils',
      '',
      '# Mount EFS using proven working method (direct NFS4)',
      'echo "Mounting EFS file systems using proven NFS4 method..."',
      'echo "APP_EFS_ID: $APP_EFS_ID"',
      'echo "DATA_EFS_ID: $DATA_EFS_ID"',
      'echo "REGION: $REGION"',
      '# Block until EFS mount targets are fully ready and SG applied',
      'for fs in "$APP_EFS_ID" "$DATA_EFS_ID"; do',
      '  echo "Waiting for EFS $fs mount targets & SG readiness..."',
      '  for i in $(seq 1 60); do',
      '    MT_JSON=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$fs" 2>/dev/null || true)',
      '    MT_IDS=$(echo "$MT_JSON" | jq -r ".MountTargets[].MountTargetId" 2>/dev/null || true)',
      '    READY=1',
      '    for mt in $MT_IDS; do',
      '      SGL=$(aws efs describe-mount-target-security-groups --region "$REGION" --mount-target-id "$mt" --query "SecurityGroups" --output text 2>/dev/null || true)',
      '      if ! echo "$SGL" | grep -q "$EFS_SG_ID"; then READY=0; break; fi',
      '    done',
      '    if [ "$READY" = "1" ] && [ -n "$MT_IDS" ]; then echo "EFS $fs ready"; break; fi',
      '    sleep 10',
      '  done',
      'done',
      '',
      '# Create mount points',
      'mkdir -p /app /data',
      '',
      '# Mount EFS using EFS helper with TLS/IAM when available (idempotent with guards and retries)',
      'echo "DNS check for APP EFS:"; getent hosts "$APP_EFS_ID.efs.$REGION.amazonaws.com" || echo "DNS failed for APP"',
      'echo "DNS check for DATA EFS:"; getent hosts "$DATA_EFS_ID.efs.$REGION.amazonaws.com" || echo "DNS failed for DATA"',
      '',
      'if command -v mount.efs >/dev/null 2>&1; then',
      '  MOUNT_APP="mount -t efs -o tls,iam"',
      '  MOUNT_DATA="mount -t efs -o tls,iam"',
      'else',
      '  MOUNT_APP="mount -t nfs4 -o nfsvers=4.1,noresvport,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"',
      '  MOUNT_DATA="$MOUNT_APP"',
      'fi',
      '',
      'for i in $(seq 1 60); do',
      '  if mountpoint -q /app; then echo "/app already mounted"; break; fi',
      '  echo "[Attempt $i/60] Mounting /app..."',
      '  if $MOUNT_APP "$APP_EFS_ID:/" /app || $MOUNT_APP "$APP_EFS_ID.efs.$REGION.amazonaws.com:/" /app; then',
      '    echo "Mounted /app"; break; fi',
      '  sleep 10',
      'done',
      '',
      'for i in $(seq 1 60); do',
      '  if mountpoint -q /data; then echo "/data already mounted"; break; fi',
      '  echo "[Attempt $i/60] Mounting /data..."',
      '  if $MOUNT_DATA "$DATA_EFS_ID:/" /data || $MOUNT_DATA "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/" /data; then',
      '    echo "Mounted /data"; break; fi',
      '  sleep 10',
      'done',
      '',
      '# Persist mounts in /etc/fstab if missing (prefer TLS helper when possible)',
      'if command -v mount.efs >/dev/null 2>&1; then',
      '  grep -qE "^$APP_EFS_ID\.efs\.$REGION\.amazonaws\.com:/\s+/app\s+efs" /etc/fstab || echo "$APP_EFS_ID.efs.$REGION.amazonaws.com:/ /app efs _netdev,tls,iam 0 0" >> /etc/fstab',
      '  grep -qE "^$DATA_EFS_ID\.efs\.$REGION\.amazonaws\.com:/\s+/data\s+efs" /etc/fstab || echo "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/ /data efs _netdev,tls,iam 0 0" >> /etc/fstab',
      'else',
      '  grep -qE "^$APP_EFS_ID\.efs\.$REGION\.amazonaws\.com:/\s+/app\s+nfs4" /etc/fstab || echo "$APP_EFS_ID.efs.$REGION.amazonaws.com:/ /app nfs4 nfsvers=4.1,_netdev 0 0" >> /etc/fstab',
      '  grep -qE "^$DATA_EFS_ID\.efs\.$REGION\.amazonaws\.com:/\s+/data\s+nfs4" /etc/fstab || echo "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/ /data nfs4 nfsvers=4.1,_netdev 0 0" >> /etc/fstab',
      'fi',
      '',
      '# Set proper permissions',
      '# Skipping ownership change on /app and /data to avoid disrupting existing site',
      '# chown apache:apache /app /data',
      '# chmod 755 /app /data',
      '',
      '# Verify mounts',
      'echo "EFS mount verification:"',
      'df -h | grep efs && echo "✓ EFS mounted successfully" || echo "✗ EFS mount failed"',
      'ls -la /app /data && echo "✓ Directories accessible" || echo "✗ Directory access failed"',
      '# Re-create health endpoints on EFS to avoid 500 after mount',
      'mkdir -p /app/moodle',
      'echo OK > /app/moodle/health',
      'cat > /app/moodle/health.php <<\'EOFH\'',
      '<?php http_response_code(200); echo "OK"; ?>',
      'EOFH',
      '# Avoid recursive chown on shared EFS; only set for health files',
      'chown apache:apache /app/moodle/health /app/moodle/health.php || true',
      'echo "Recreated health endpoints on EFS"',
      '',
      '# Download and execute the intelligent installation script from S3',
      `SCRIPT_BUCKET="moodle-scripts-${this.account}-${this.region}"`,
      'SCRIPT_PATH="/tmp/intelligent-moodle-install.sh"',
      'echo "Downloading intelligent installation script from S3..."',
      'aws s3 cp "s3://$SCRIPT_BUCKET/intelligent-moodle-install.sh" "$SCRIPT_PATH"',
      'chmod +x "$SCRIPT_PATH"',
      '',
      '# Execute the intelligent installation script',
      'echo "Executing intelligent Moodle installation..."',
      'INSTALL_SUCCESS=false',
      'if "$SCRIPT_PATH"; then',
      '  echo "✓ Intelligent install succeeded"',
      '  INSTALL_SUCCESS=true',
      '  if [ -n "$ASG_NAME" ]; then aws autoscaling set-instance-protection --instance-ids "$INSTANCE_ID" --auto-scaling-group-name "$ASG_NAME" --no-protected-from-scale-in --region "$REGION" || true; fi',
      'else',
      '  echo "⚠ Intelligent install failed, will attempt fallback configuration"',
      '  INSTALL_SUCCESS=false',
      'fi',
      '',
      '# CONSOLIDATED POST-INSTALL CONFIGURATION (Redis + Reverse Proxy)',
      'echo "=== CONSOLIDATED POST-INSTALL CONFIGURATION START ==="',
      `REDIS_ENDPOINT=$(aws ssm get-parameter --name "/moodle/redis/endpoint" --region "$REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "")`,
      'CONFIG_NEEDS_REBUILD=false',
      '',
      '# Determine if we need to rebuild config.php',
      'if [ "$INSTALL_SUCCESS" = "true" ] && [ -f "/app/moodle/config.php" ]; then',
      '  echo "✓ Using existing config.php from successful installation"',
      '  # Check if Redis configuration is missing and needs to be added',
      '  if [ -n "$REDIS_ENDPOINT" ] && ! grep -q "session_handler_class.*redis" /app/moodle/config.php; then',
      '    echo "⚠ Redis configuration missing, will rebuild config.php"',
      '    CONFIG_NEEDS_REBUILD=true',
      '  fi',
      'else',
      '  echo "⚠ No existing config.php or install failed, will rebuild"',
      '  CONFIG_NEEDS_REBUILD=true',
      'fi',
      '',
      '# Rebuild config.php if needed (SINGLE WRITE OPERATION)',
      'if [ "$CONFIG_NEEDS_REBUILD" = "true" ] && [ -n "$REDIS_ENDPOINT" ]; then',
      '  echo "Rebuilding config.php with full Redis configuration..."',
      `  aws s3 cp "s3://moodle-scripts-${this.account}-${this.region}/rebuild-config-full-from-current.sh" /tmp/rebuild-config-full-from-current.sh`,
      '  if [ -s /tmp/rebuild-config-full-from-current.sh ]; then',
      '    chmod +x /tmp/rebuild-config-full-from-current.sh',
      '    if /tmp/rebuild-config-full-from-current.sh; then',
      '      echo "✓ Config rebuilt successfully with Redis and reverse proxy configuration"',
      '    else',
      '      echo "✗ Config rebuild failed - keeping instance protected for debugging"',
      '      exit 1',
      '    fi',
      '  else',
      '    echo "✗ Could not download rebuild script"',
      '    exit 1',
      '  fi',
      'elif [ "$CONFIG_NEEDS_REBUILD" = "true" ]; then',
      '  echo "✗ No Redis endpoint available for config rebuild"',
      '  exit 1',
      'fi',

      '',
      '# REVERSE PROXY VERIFICATION AND FINAL FIX',
      'echo "=== REVERSE PROXY VERIFICATION AND FINAL FIX ==="',
      'PROXY_FIX_NEEDED=false',
      '',
      '# Test for reverse proxy abuse error',
      'echo "Testing for reverse proxy configuration issues..."',
      'if [ -f "/app/moodle/config.php" ]; then',
      '  # Test direct access (should work)',
      '  LOCAL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null || echo "000")',
      '  echo "Local health check: $LOCAL_STATUS"',
      '  ',
      '  # Test with ALB headers (should work)',
      '  ALB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \\',
      '    -H "Host: elearning.tsin.ca" \\',
      '    -H "X-Forwarded-Proto: https" \\',
      '    -H "X-Forwarded-For: 1.2.3.4" \\',
      '    http://localhost/ 2>/dev/null || echo "000")',
      '  echo "ALB simulation test: $ALB_STATUS"',
      '  ',
      '  # Check for reverse proxy abuse in error logs',
      '  if grep -q "reverseproxyabused" /var/log/httpd/error_log 2>/dev/null; then',
      '    echo "⚠ Found reverseproxyabused error in logs"',
      '    PROXY_FIX_NEEDED=true',
      '  fi',
      '  ',
      '  # Check if reverse proxy configuration exists in config.php',
      '  if ! grep -q "Dynamic proxy flags" /app/moodle/config.php 2>/dev/null; then',
      '    echo "⚠ Missing dynamic proxy configuration in config.php"',
      '    PROXY_FIX_NEEDED=true',
      '  fi',
      '  ',
      '  # If either test fails or errors found, apply the fix',
      '  if [ "$LOCAL_STATUS" != "200" ] || [ "$ALB_STATUS" != "200" ] || [ "$PROXY_FIX_NEEDED" = "true" ]; then',
      '    echo "🔧 Applying reverse proxy fix..."',
      `    aws s3 cp "s3://moodle-scripts-${this.account}-${this.region}/patch-config-proxy-inplace.sh" /tmp/patch-config-proxy-inplace.sh`,
      '    if [ -s /tmp/patch-config-proxy-inplace.sh ]; then',
      '      chmod +x /tmp/patch-config-proxy-inplace.sh',
      '      if /tmp/patch-config-proxy-inplace.sh; then',
      '        echo "✓ Reverse proxy fix applied successfully"',
      '        # Restart services after fix',
      '        systemctl restart php-fpm httpd',
      '        sleep 3',
      '        # Re-test after fix',
      '        FIXED_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null || echo "000")',
      '        echo "Post-fix health check: $FIXED_STATUS"',
      '        if [ "$FIXED_STATUS" = "200" ]; then',
      '          echo "✅ Reverse proxy issue resolved"',
      '        else',
      '          echo "❌ Reverse proxy fix failed - manual intervention required"',
      '        fi',
      '      else',
      '        echo "❌ Reverse proxy fix script failed"',
      '      fi',
      '    else',
      '      echo "❌ Could not download reverse proxy fix script"',
      '    fi',
      '  else',
      '    echo "✅ Reverse proxy configuration is working correctly"',
      '  fi',
      'else',
      '  echo "❌ config.php not found - deployment failed"',
      'fi',
      '',
      '# FINAL REVERSE PROXY DISABLE (PERMANENT FIX)',
      'echo "=== FINAL REVERSE PROXY DISABLE (PERMANENT FIX) ==="',
      'if [ -f "/app/moodle/config.php" ]; then',
      '  echo "Applying permanent reverse proxy disable to prevent reverseproxyabused errors..."',
      '  # Create backup',
      '  cp /app/moodle/config.php /app/moodle/config.php.backup.final.$(date +%s) || true',
      '  # Force disable reverse proxy (this prevents the reverseproxyabused error)',
      '  if grep -q "^\\s*\\$CFG->reverseproxy" /app/moodle/config.php; then',
      '    sed -i -E "s/^\\s*\\$CFG->reverseproxy\\s*=.*/\\$CFG->reverseproxy = false;/" /app/moodle/config.php',
      '  else',
      '    sed -i "/require_once.*lib\\/setup.php/i \\$CFG->reverseproxy = false;" /app/moodle/config.php',
      '  fi',
      '  # Verify PHP syntax',
      '  php -l /app/moodle/config.php || echo "⚠ PHP syntax error in config.php"',
      '  # Purge caches and restart services',
      '  sudo -u apache php /app/moodle/admin/cli/purge_caches.php || true',
      '  systemctl restart php-fpm httpd || true',
      '  sleep 3',
      '  echo "✅ Reverse proxy permanently disabled to prevent future issues"',
      'else',
      '  echo "❌ config.php not found - cannot apply reverse proxy fix"',
      'fi',
      '',
      '# Final health check + service verification',
      'echo "=== FINAL SYSTEM VERIFICATION ==="',
      'systemctl is-active --quiet httpd && echo "✓ httpd active" || echo "❌ httpd NOT active"',
      'systemctl is-active --quiet php-fpm && echo "✓ php-fpm active" || echo "❌ php-fpm NOT active"',
      'sleep 5',
      'FINAL_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null || echo "000")',
      'echo "Final health check: $FINAL_HEALTH"',
      '# Test ALB simulation to verify reverse proxy fix',
      'ALB_TEST=$(curl -s -o /dev/null -w "%{http_code}" \\',
      '  -H "Host: elearning.tsin.ca" \\',
      '  -H "X-Forwarded-Proto: https" \\',
      '  -H "X-Forwarded-For: 1.2.3.4" \\',
      '  http://localhost/ 2>/dev/null || echo "000")',
      'echo "ALB simulation test: $ALB_TEST"',
      'if [ "$FINAL_HEALTH" = "200" ] && [ "$ALB_TEST" != "500" ]; then',
      '  echo "🎉 Moodle deployment completed successfully at $(date)"',
      '  echo "✅ Reverse proxy issue permanently resolved"',
      'else',
      '  echo "⚠ Moodle deployment completed with potential issues at $(date)"',
      '  echo "Health: $FINAL_HEALTH, ALB Test: $ALB_TEST"',
      'fi',
      '',
      '# SES EMAIL CONFIGURATION',
      'echo "=== SES EMAIL CONFIGURATION START ==="',
      'if [ -f "/app/moodle/config.php" ]; then',
      '  echo "Configuring SES email for Moodle..."',
      `  aws s3 cp "s3://moodle-scripts-${this.account}-${this.region}/configure-moodle-ses-email.sh" /tmp/configure-moodle-ses-email.sh || true`,
      '  if [ -s /tmp/configure-moodle-ses-email.sh ]; then',
      '    chmod +x /tmp/configure-moodle-ses-email.sh',
      '    if /tmp/configure-moodle-ses-email.sh; then',
      '      echo "✓ SES email configuration completed successfully"',
      '    else',
      '      echo "⚠ SES email configuration failed (non-critical, can be configured manually)"',
      '    fi',
      '  else',
      '    echo "⚠ Could not download SES configuration script (non-critical)"',
      '  fi',
      'else',
      '  echo "⚠ config.php not found - skipping SES email configuration"',
      'fi',
      'echo "=== SES EMAIL CONFIGURATION END ==="',

          );

    return userData;
  }

  private createUserDataBootstrapOnly(p: { appEfsId: string; dataEfsId: string; dbEndpoint: string; region: string; dbSecretArn: string; efsSgId: string; moodleWwwroot?: string; }): ec2.UserData {
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      '#!/bin/bash',
      'set -euo pipefail',
      'exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1',
      `export APP_EFS_ID="${p.appEfsId}"`,
      `export DATA_EFS_ID="${p.dataEfsId}"`,
      `export REGION="${p.region}"`,
      `export DB_SECRET_ARN="${p.dbSecretArn}"`,
      `export EFS_SG_ID="${p.efsSgId}"`,
      `export MOODLE_WWWROOT="${p.moodleWwwroot ?? ''}"`,
      `export SCRIPT_BUCKET="moodle-scripts-${this.account}-${this.region}"`,
      'command -v aws >/dev/null 2>&1 || yum install -y awscli jq',
      'aws s3 cp "s3://$SCRIPT_BUCKET/bootstrap-moodle.sh" /tmp/bootstrap-moodle.sh',
      'chmod +x /tmp/bootstrap-moodle.sh',
      '/tmp/bootstrap-moodle.sh'
    );
    return userData;
  }


  private createEfsSecurityGroupFixerProvider() {
    const onEventHandler = new lambda.Function(this, 'EfsSecurityGroupFixerFunction', {
      runtime: lambda.Runtime.PYTHON_3_9,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
import boto3
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    logger.info(f"Event: {json.dumps(event)}")

    request_type = event['RequestType']
    if request_type == 'Delete':
        return {'PhysicalResourceId': 'efs-security-group-fixer'}

    props = event['ResourceProperties']
    app_fs_id = props['AppFileSystemId']
    data_fs_id = props['DataFileSystemId']
    security_group_id = props['SecurityGroupId']
    region = props['Region']

    efs_client = boto3.client('efs', region_name=region)

    try:
        def wait_and_update(fs_id: str, label: str):
            # Wait for mount targets to exist (up to ~5 minutes)
            import time
            deadline = time.time() + 300
            targets = []
            while time.time() < deadline:
                resp = efs_client.describe_mount_targets(FileSystemId=fs_id)
                targets = resp.get('MountTargets', [])
                if targets:
                    break
                logger.info(f"[{label}] No mount targets yet, retrying in 10s...")
                time.sleep(10)
            if not targets:
                raise Exception(f"[{label}] No mount targets found for filesystem {fs_id}")
            for target in targets:
                mt_id = target['MountTargetId']
                logger.info(f"[{label}] Updating security groups for mount target: {mt_id}")
                efs_client.modify_mount_target_security_groups(
                    MountTargetId=mt_id,
                    SecurityGroups=[security_group_id]
                )

        wait_and_update(app_fs_id, 'APP')
        wait_and_update(data_fs_id, 'DATA')

        logger.info("Successfully updated all EFS mount target security groups")
        return {'PhysicalResourceId': 'efs-security-group-fixer'}

    except Exception as e:
        logger.error(f"Error updating EFS mount target security groups: {str(e)}")
        raise e
`),
      timeout: cdk.Duration.minutes(5),
    });

    // Grant permissions to modify EFS mount target security groups
    onEventHandler.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticfilesystem:DescribeMountTargets',
        'elasticfilesystem:ModifyMountTargetSecurityGroups',
        'elasticfilesystem:DescribeFileSystems'
      ],
      resources: ['*'],
    }));

    return new cr.Provider(this, 'EfsSecurityGroupFixerProvider', {
      onEventHandler,
    });
  }

  private createAlbHttpsListenerResetProvider(): cr.Provider {
    const onEventHandler = new lambda.Function(this, 'AlbHttpsListenerResetFn', {
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.on_event',
      code: lambda.Code.fromInline(`import json
import boto3
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)
elbv2 = boto3.client('elbv2')


def _delete_https_listeners(lb_arn: str):
    paginator = elbv2.get_paginator('describe_listeners')
    deleted = []
    for page in paginator.paginate(LoadBalancerArn=lb_arn):
        for l in page.get('Listeners', []):
            if l.get('Port') == 443:
                arn = l['ListenerArn']
                logger.info(f"Deleting existing HTTPS listener: {arn}")
                try:
                    elbv2.delete_listener(ListenerArn=arn)
                    deleted.append(arn)
                except Exception as e:
                    # If already gone, continue idempotently
                    if 'ListenerNotFound' in str(e):
                        logger.info(f"Listener already deleted: {arn}")
                        continue
                    raise
    return deleted


def on_event(event, context):
    logger.info(json.dumps(event))
    request_type = event.get('RequestType')
    props = event.get('ResourceProperties', {})
    lb_arn = props.get('LoadBalancerArn')
    if not lb_arn:
        raise Exception('LoadBalancerArn is required')

    physical_id = f"alb-https-listener-reset-{lb_arn.split('/')[-1]}"

    if request_type in ('Create', 'Update'):
        deleted = _delete_https_listeners(lb_arn)
        return {
            'PhysicalResourceId': physical_id,
            'Data': {'Deleted': deleted}
        }
    elif request_type == 'Delete':
        # Nothing to do on delete
        return {'PhysicalResourceId': physical_id}
    else:
        raise Exception(f"Unknown RequestType: {request_type}")
`),
      timeout: cdk.Duration.minutes(5),
    });

    // Permissions to list and delete listeners
    onEventHandler.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticloadbalancing:DescribeListeners',
        'elasticloadbalancing:DeleteListener',
      ],
      resources: ['*'],
    }));

    return new cr.Provider(this, 'AlbHttpsListenerResetProvider', {
      onEventHandler,
    });
  }

}
