# Moodle 5.0 CDK Deployment

This AWS CDK project deploys a scalable Moodle 5.0 learning management system with MariaDB 10.11 on AWS infrastructure.

## Architecture

- **VPC**: Multi-AZ VPC with public and private subnets
- **Database**: MariaDB 10.11 RDS instance with Multi-AZ deployment
- **Storage**: Two EFS file systems for shared `/data` and `/app` directories
- **Compute**: Auto Scaling Group with Launch Templates for Moodle servers
- **Load Balancer**: Application Load Balancer for high availability
- **Monitoring**: CloudWatch logs and metrics for comprehensive monitoring

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Node.js 18+ installed
3. AWS CDK CLI installed (`npm install -g aws-cdk`)
4. Sufficient AWS permissions for creating VPC, RDS, EFS, EC2, ALB, and IAM resources

## Deployment

1. **Install dependencies:**
   ```bash
   npm install
   ```

2. **Bootstrap CDK (if not done before):**
   ```bash
   cdk bootstrap aws://ACCOUNT-NUMBER/ca-central-1
   ```

3. **Deploy the stack:**
   ```bash
   cdk deploy
   ```

4. **Access Moodle:**
   - After deployment, use the ALB URL from the CloudFormation outputs
   - Initial admin credentials:
     - Username: `moodle-admin`
     - Password: `TempPass123!` (change immediately after first login)

## Configuration Details

### Database
- **Engine**: MariaDB 10.11
- **Instance**: db.t3.micro (development)
- **Multi-AZ**: Enabled for high availability
- **Backup**: 7-day retention
- **Encryption**: Enabled

### Moodle Servers
- **Instance Type**: t3.medium
- **OS**: Amazon Linux 2023
- **PHP**: 8.3 with optimized configuration for Moodle 5.0
- **Auto Scaling**: Min 1, Max 1 (development)

### Storage
- **EFS Data**: Shared `/data` directory for Moodle data
- **EFS App**: Shared `/app` directory for Moodle application
- **Lifecycle**: Files moved to IA after 30 days

### Security
- **Security Groups**: Properly configured for minimal access
- **IAM Roles**: Least privilege access for EC2 instances
- **Secrets Manager**: Database credentials securely stored
- **IMDSv2**: Required for EC2 metadata access

## Monitoring and Logging

### CloudWatch Log Groups
- `/aws/ec2/moodle`: Moodle-specific logs
- `/aws/ec2/system`: System and application logs

### Metrics
- EC2 instance metrics (CPU, memory, disk)
- RDS performance metrics
- ALB request metrics

## Maintenance

### Updates
The deployment script automatically handles:
- First-time Moodle installation
- Database initialization
- Moodle updates without database recreation

### Scaling
To increase capacity:
1. Update the Auto Scaling Group max capacity in the CDK code
2. Redeploy: `cdk deploy`

### Backup
- RDS automated backups (7 days)
- EFS automatic backups can be enabled
- Consider additional backup strategies for production

## Troubleshooting

### Check Instance Status
```bash
# View CloudWatch logs
aws logs describe-log-groups --log-group-name-prefix "/aws/ec2"

# Check Auto Scaling Group
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroup*
```

### Common Issues
1. **Health Check Failures**: Check security groups and Moodle configuration
2. **Database Connection**: Verify RDS security group allows access from Moodle instances
3. **EFS Mount Issues**: Ensure EFS security group allows NFS traffic

## Security Considerations

### Production Recommendations
1. **SSL/TLS**: Add HTTPS listener with ACM certificate
2. **WAF**: Consider AWS WAF for additional protection
3. **Backup**: Implement comprehensive backup strategy
4. **Monitoring**: Set up CloudWatch alarms for critical metrics
5. **Updates**: Regular security updates for OS and Moodle

### Network Security
- Database in isolated subnets
- Moodle servers in private subnets
- ALB in public subnets only

## Cost Optimization

### Development Environment
Current configuration optimized for development:
- db.t3.micro RDS instance
- t3.medium EC2 instances
- Single instance deployment

### Production Considerations
- Upgrade to larger instance types
- Enable Multi-AZ for RDS
- Increase Auto Scaling Group capacity
- Consider Reserved Instances for cost savings

## Cleanup

To destroy all resources:
```bash
cdk destroy
```

**Warning**: This will delete all data including the database and EFS file systems.

## Support

For issues related to:
- **AWS Infrastructure**: Check CloudFormation events and CloudWatch logs
- **Moodle Configuration**: Refer to Moodle documentation
- **CDK Deployment**: Check CDK documentation and AWS CDK GitHub issues
