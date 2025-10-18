# Moodle CDK Scripts Review

## Current Status
- **Load Balancer**: Active (`Moodle-Moodl-JabjSDOCuhdn`)
- **Target Instances**: 2 instances healthy on port 80
- **Database**: Available (MariaDB)
- **Instance Status**: Running and OK
- **Apache**: Active
- **Issue**: HTTP requests timing out (possible application issue)

## Available Scripts by Category

### 1. **Diagnostic Scripts** (For Troubleshooting)

#### `run-ssm-500-diag.ps1` ⭐ **START HERE**
- **Purpose**: Comprehensive diagnostic for 500 errors and application issues
- **What it does**:
  - Checks services (httpd, php-fpm)
  - Verifies PHP configuration and modules
  - Lints Moodle config.php
  - Checks file permissions and SELinux
  - Tests database connectivity
  - Collects Apache and Moodle error logs
  - Tests localhost HTTP responses
- **Usage**: `./scripts/run-ssm-500-diag.ps1`
- **Output**: Saved to `scripts/outputs/500-diag-stdout.txt` and `500-diag-stderr.txt`

#### `ssm-collect-500.json`
- SSM document used by `run-ssm-500-diag.ps1`
- Contains all diagnostic commands

#### `ssm-verify-apache.json`
- Lightweight Apache verification
- Checks services, vhosts, health endpoint
- Used by `deploy-and-verify-http.ps1`

### 2. **Recovery/Fix Scripts**

#### `ssm-apache-fix.json`
- **Purpose**: Repair Apache and PHP installation
- **What it does**:
  - Installs/reinstalls httpd and PHP packages
  - Creates minimal Moodle directory structure
  - Generates Apache vhost configuration
  - Handles SELinux contexts
  - Restarts Apache
- **Usage**: Via SSM send-command with this JSON

#### `rotate-asg.ps1`
- **Purpose**: Replace unhealthy instance with new one
- **What it does**:
  - Scales ASG to 2 instances
  - Waits for new instance to become healthy
  - Terminates old instance
  - Scales back to 1
- **Usage**: `./scripts/rotate-asg.ps1`
- **When to use**: If current instance is corrupted/unrecoverable

### 3. **Verification Scripts**

#### `verify-external-http.ps1`
- Tests HTTP connectivity from local machine to ALB
- Checks for redirect loops
- Verifies `/health` endpoint
- Usage: `./scripts/verify-external-http.ps1`

#### `ssm-verify-http-redirects.json`
- Tests HTTP from instance perspective
- Checks localhost and ALB URLs
- Verifies config settings

#### `deploy-and-verify-http.ps1`
- Full deployment + verification pipeline
- Builds CDK, deploys, waits 90s, runs verification
- Usage: `./scripts/deploy-and-verify-http.ps1`

### 4. **Email/SES Scripts** (Not relevant for current issue)
- `configure-moodle-ses-email.sh`
- `deploy-ses-email-config.ps1`
- `diagnose-ses-email.sh`
- `send-test-email.sh`

## Recommended Troubleshooting Steps

### Step 1: Run Comprehensive Diagnostics
```powershell
./scripts/run-ssm-500-diag.ps1
```
This will collect all diagnostic information and save to `scripts/outputs/`.

### Step 2: Review Diagnostic Output
Check the generated files:
- `500-diag-stdout.txt` - Main diagnostic output
- `500-diag-stderr.txt` - Error messages

### Step 3: Based on Findings

**If Apache/PHP is broken:**
- Use SSM to run `ssm-apache-fix.json` commands

**If instance is corrupted:**
- Run `./scripts/rotate-asg.ps1` to replace with fresh instance

**If HTTP redirects are looping:**
- Check Moodle config.php settings (wwwroot, reverseproxy, sslproxy)
- Use `ssm-verify-http-redirects.json` to test

**If database connectivity fails:**
- Check security groups
- Verify RDS endpoint and credentials

## Quick Command Reference

```powershell
# Diagnose the issue
./scripts/run-ssm-500-diag.ps1

# Fix Apache if needed (via SSM)
aws ssm send-command --instance-ids i-0eab4573101db727a `
  --document-name AWS-RunShellScript `
  --parameters file://scripts/ssm-apache-fix.json

# Replace instance if corrupted
./scripts/rotate-asg.ps1

# Verify external HTTP access
./scripts/verify-external-http.ps1
```

## Next Steps
1. Run `run-ssm-500-diag.ps1` to identify the root cause
2. Share the output from `scripts/outputs/500-diag-stdout.txt`
3. Based on findings, apply appropriate fix

