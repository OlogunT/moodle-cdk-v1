# Moodle 5.0 AWS CDK Deployment Guide

## 🎯 Overview

This project deploys **Moodle 5.0** (the latest version) on AWS using CDK with the following specifications:

### ✅ Moodle 5.0 Requirements Met
- **Moodle Version**: 5.0 (main branch) - Latest release
- **PHP Version**: 8.3 (supports 8.2, 8.3, and 8.4 as per Moodle 5.0 requirements)
- **Database**: MariaDB 10.11 (minimum required for Moodle 5.0)
- **PHP Extensions**: All required extensions including sodium
- **Configuration**: Optimized for Moodle 5.0 performance

### 🏗️ Architecture Components

#### **Infrastructure**
- **VPC**: Multi-AZ (2 zones) with public/private/database subnets
- **Launch Templates**: Used for Auto Scaling Groups as requested
- **Auto Scaling**: Min 1, Max 1 (development configuration)
- **Load Balancer**: Application Load Balancer with health checks

#### **Database**
- **Engine**: MariaDB 10.11.0+ (Moodle 5.0 compatible)
- **Instance**: db.t3.micro (development)
- **Multi-AZ**: Enabled for high availability
- **Backup**: 7-day retention with encryption

#### **Storage (EFS)**
- **Data EFS**: `/data` directory shared across instances
- **App EFS**: `/app` directory shared across instances
- **Lifecycle**: Files moved to IA after 30 days

#### **Compute**
- **Instance Type**: t3.medium
- **OS**: Amazon Linux 2023
- **PHP**: 8.3 with Moodle 5.0 optimizations
- **Launch Template**: Configured for Auto Scaling Groups

## 🚀 Quick Start

### 1. Deploy Infrastructure
```powershell
# Install dependencies
npm install

# Deploy the stack
.\deploy.ps1
```

### 2. Monitor Installation
```powershell
# Watch installation progress
.\monitor.ps1 -Action logs

# Check when ready
.\monitor.ps1 -Action health
```

### 3. Update Moodle URL (Important!)
```powershell
# After deployment completes, update Moodle with correct ALB URL
.\scripts\update-moodle-url.ps1
```

### 4. Access Moodle
- Use the ALB URL from CloudFormation outputs
- Login: `moodle-admin` / `TempPass123!`
- **Change password immediately!**

## 📋 Moodle 5.0 Specific Features

### **System Requirements Met**
- ✅ PHP 8.3 (minimum 8.2.0 required)
- ✅ MariaDB 10.11.0+ (minimum required)
- ✅ PHP sodium extension (required)
- ✅ max_input_vars >= 5000 (set to 5000)
- ✅ 64-bit PHP support

### **Optimized Configuration**
- **Memory**: 512M PHP memory limit
- **OPcache**: 256M with 10,000 max files
- **Upload**: 512M max file size
- **Timezone**: America/Toronto
- **Session**: File-based storage

### **Security Features**
- ✅ IMDSv2 required on EC2 instances
- ✅ Encrypted RDS storage
- ✅ Security groups with minimal access
- ✅ Secrets Manager for database credentials
- ✅ Private subnets for compute and database

## 🔧 Management Scripts

### **Deployment**
```powershell
.\deploy.ps1                    # Deploy stack
.\deploy.ps1 -Action destroy    # Destroy stack
.\deploy.ps1 -Force             # Skip confirmations
```

### **Monitoring**
```powershell
.\monitor.ps1                           # Show status
.\monitor.ps1 -Action logs              # Tail logs
.\monitor.ps1 -Action health            # Test accessibility
.\monitor.ps1 -Action troubleshoot      # Run diagnostics
```

### **URL Update**
```powershell
.\scripts\update-moodle-url.ps1        # Update Moodle with ALB URL
```

## 🎯 Post-Deployment Steps

### **1. Initial Setup**
1. Wait 5-10 minutes for installation to complete
2. Run URL update script: `.\scripts\update-moodle-url.ps1`
3. Access Moodle at ALB URL
4. Login and change admin password

### **2. Moodle Configuration**
- Configure site settings
- Set up user authentication
- Install additional plugins if needed
- Configure backup schedules

### **3. Production Readiness**
For production deployment, consider:
- Increase Auto Scaling Group capacity
- Upgrade to larger instance types
- Enable additional monitoring
- Set up SSL/TLS with ACM
- Configure Route 53 for custom domain

## 🔍 Troubleshooting

### **Common Issues**

#### **Moodle Not Accessible**
```powershell
# Check instance status
.\monitor.ps1 -Action status

# Check logs for errors
.\monitor.ps1 -Action logs

# Test health
.\monitor.ps1 -Action health
```

#### **Database Connection Issues**
- Verify RDS is running
- Check security group rules
- Confirm credentials in Secrets Manager

#### **EFS Mount Issues**
- Verify EFS security group allows NFS (port 2049)
- Check mount targets in correct subnets

### **Log Locations**
- **System Logs**: `/aws/ec2/system` CloudWatch log group
- **Moodle Logs**: `/aws/ec2/moodle` CloudWatch log group
- **Installation**: `/var/log/user-data.log` on instances

## 📊 Monitoring

### **CloudWatch Metrics**
- EC2 instance metrics (CPU, memory, disk)
- RDS performance metrics
- ALB request metrics
- EFS performance metrics

### **Health Checks**
- ALB health check on `/login/index.php`
- Auto Scaling Group health checks
- RDS availability monitoring

## 🔒 Security Best Practices

### **Implemented**
- Database in isolated subnets
- Encrypted storage (RDS and EFS)
- IAM roles with least privilege
- Security groups with minimal access
- Secrets Manager for credentials

### **Recommended for Production**
- Enable AWS WAF
- Set up CloudTrail logging
- Configure GuardDuty
- Implement backup strategy
- Regular security updates

## 📈 Scaling

### **Current Configuration**
- Min: 1 instance
- Max: 1 instance
- Development optimized

### **Production Scaling**
Update CDK code to increase:
- Auto Scaling Group capacity
- Instance types (t3.large or larger)
- RDS instance class
- Enable Multi-AZ for all components

## 🆘 Support

### **Resources**
- [Moodle 5.0 Documentation](https://docs.moodle.org/)
- [Moodle 5.0 Release Notes](https://moodledev.io/general/releases/5.0)
- [AWS CDK Documentation](https://docs.aws.amazon.com/cdk/)

### **Getting Help**
1. Check CloudWatch logs first
2. Use monitoring scripts for diagnostics
3. Review Moodle and AWS documentation
4. Check security group configurations

---

**Note**: This deployment is configured for development use. For production, review and adjust security settings, instance sizes, and monitoring configurations according to your requirements.
