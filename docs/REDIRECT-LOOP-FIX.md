# Moodle Redirect Loop Fix

## Problem: ERR_TOO_MANY_REDIRECTS

When accessing the Moodle site at `https://elearning.tsin.ca`, you may encounter:

```
This page isn't working right now
elearning.tsin.ca redirected you too many times.

Try deleting the cookies for this site
ERR_TOO_MANY_REDIRECTS
```

## Root Cause

The redirect loop occurs when Moodle is deployed behind an Application Load Balancer (ALB) with SSL termination, and the Moodle configuration has incorrect reverse proxy settings.

### Technical Details

1. **The Setup:**
   - User requests `https://elearning.tsin.ca/`
   - ALB receives HTTPS request on port 443
   - ALB terminates SSL and forwards to backend EC2 instances on HTTP port 80
   - ALB adds headers: `X-Forwarded-Proto: https`, `X-Forwarded-Port: 443`

2. **The Problem:**
   - When `$CFG->reverseproxy = true` in Moodle's `config.php`, Moodle blocks direct access with error: "Reverse proxy enabled so the server cannot be accessed directly"
   - When `$CFG->reverseproxy = false` but `$CFG->sslproxy` is missing or false, Moodle doesn't recognize the ALB's SSL termination
   - Moodle sees the backend HTTP request but `$CFG->wwwroot` is set to HTTPS
   - Moodle redirects HTTP → HTTPS infinitely

3. **The Solution:**
   - Set `$CFG->sslproxy = true` - tells Moodle to trust the `X-Forwarded-Proto` header from ALB
   - Remove `$CFG->reverseproxy` or set it to `false` - allows direct access from ALB
   - Ensure `$CFG->wwwroot = 'https://elearning.tsin.ca'`

## Quick Fix

### Option 1: PowerShell Script (Windows/Cross-platform)

```powershell
# Fix all instances with default settings
./scripts/fix-redirect-loop.ps1

# Fix with custom domain
./scripts/fix-redirect-loop.ps1 -CustomDomain "https://moodle.example.com"

# Fix specific instance
./scripts/fix-redirect-loop.ps1 -InstanceIds i-1234567890abcdef0

# Fix without verification
./scripts/fix-redirect-loop.ps1 -VerifyAfter:$false
```

### Option 2: Bash Script (Linux/Mac)

```bash
# Make script executable
chmod +x scripts/fix-redirect-loop.sh

# Fix all instances with default settings
./scripts/fix-redirect-loop.sh

# Fix with custom domain
CUSTOM_DOMAIN="https://moodle.example.com" ./scripts/fix-redirect-loop.sh

# Fix without verification
VERIFY_AFTER=false ./scripts/fix-redirect-loop.sh
```

## What the Scripts Do

1. **Find Instances:** Automatically discovers all healthy EC2 instances in the Moodle Auto Scaling Group
2. **Backup Config:** Creates a timestamped backup of `config.php` before making changes
3. **Fix Configuration:**
   - Removes problematic settings: `$CFG->reverseproxy`, `$CFG->getremoteaddrconf`, `$CFG->cookiesecure`, `$CFG->loginhttps`
   - Adds correct setting: `$CFG->sslproxy = true;`
   - Ensures `$CFG->wwwroot` uses HTTPS
4. **Clear Caches:** Removes Moodle cache files and runs cache purge CLI
5. **Restart Services:** Restarts PHP-FPM and Apache to apply changes
6. **Verify:** Tests the site to confirm the redirect loop is fixed

## Manual Fix (If Scripts Fail)

If you need to fix manually via AWS Systems Manager:

1. **Connect to instance via SSM:**
   ```bash
   aws ssm start-session --target i-INSTANCE_ID --region ca-central-1
   ```

2. **Edit config.php:**
   ```bash
   sudo -i
   cd /app/moodle
   cp config.php config.php.backup.$(date +%Y%m%d_%H%M%S)
   nano config.php
   ```

3. **Make these changes:**
   ```php
   // REMOVE or comment out these lines:
   // $CFG->reverseproxy = true;
   // $CFG->getremoteaddrconf = 0;
   // $CFG->cookiesecure = true;
   // $CFG->loginhttps = 0;
   
   // ADD this line BEFORE require_once:
   $CFG->sslproxy = true;
   
   // ENSURE wwwroot uses HTTPS:
   $CFG->wwwroot = 'https://elearning.tsin.ca';
   
   require_once(__DIR__ . '/lib/setup.php');
   ```

4. **Clear caches and restart:**
   ```bash
   rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/*
   sudo -u apache php admin/cli/purge_caches.php
   systemctl restart php-fpm httpd
   ```

5. **Test:**
   ```bash
   curl -I http://localhost/
   ```

## Verification

After applying the fix, verify the site is working:

```bash
# Test health endpoint
curl -s https://elearning.tsin.ca/health

# Test homepage (should not redirect infinitely)
curl -sL --max-redirs 20 -w "\nRedirects: %{num_redirects}\n" -o /dev/null https://elearning.tsin.ca/

# Check for login page
curl -sL https://elearning.tsin.ca/ | grep -i "log in"
```

**Expected Results:**
- Health endpoint returns: `OK`
- Homepage redirects: 0-2 redirects (not 10+)
- Login page loads successfully
- No error messages about reverse proxy

## Prevention

To prevent this issue in future deployments, the CDK userdata script (`scripts/intelligent-moodle-install.sh`) has been updated to use the correct configuration from the start:

```bash
# In set_proxy_flags_in_config function:
if [ "$proto" = "https" ]; then
  # For HTTPS with ALB SSL termination:
  # - sslproxy=true tells Moodle to trust X-Forwarded-Proto
  # - reverseproxy should NOT be set (or set to false)
  sed -i "/require_once.*lib\/setup\.php/i \$CFG->sslproxy = true;" "$cfg"
fi
```

## Troubleshooting

### Issue: Script can't find instances
**Solution:** Check that the Auto Scaling Group exists and has healthy instances:
```bash
aws autoscaling describe-auto-scaling-groups --region ca-central-1 \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'Moodle')]"
```

### Issue: SSM command fails
**Solution:** Verify SSM agent is running and instance has proper IAM role:
```bash
aws ssm describe-instance-information --region ca-central-1 \
  --filters "Key=InstanceIds,Values=i-INSTANCE_ID"
```

### Issue: Still getting redirect loop after fix
**Solution:** 
1. Check if both instances were fixed (ASG has 2 instances)
2. Clear browser cookies for the site
3. Verify config.php on the instance:
   ```bash
   grep -E '(wwwroot|sslproxy|reverseproxy)' /app/moodle/config.php
   ```
4. Check Apache is forwarding X-Forwarded headers correctly

### Issue: "Reverse proxy enabled" error
**Solution:** This means `$CFG->reverseproxy = true` is still in config.php. Remove it completely.

## Configuration Reference

### Correct Configuration (ALB with SSL Termination)
```php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'database-endpoint.rds.amazonaws.com';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodleuser';
$CFG->dbpass    = 'password';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = array(
  'dbpersist' => 0,
  'dbport' => 3306,
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

$CFG->wwwroot   = 'https://elearning.tsin.ca';
$CFG->dataroot  = '/data/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;

// SSL proxy setting for ALB SSL termination
$CFG->sslproxy = true;

require_once(__DIR__ . '/lib/setup.php');
```

### Incorrect Configurations

❌ **Wrong: reverseproxy = true**
```php
$CFG->reverseproxy = true;  // Blocks direct access from ALB
$CFG->sslproxy = true;
```

❌ **Wrong: Missing sslproxy**
```php
$CFG->wwwroot = 'https://elearning.tsin.ca';
// Missing $CFG->sslproxy = true;
// Causes redirect loop
```

❌ **Wrong: HTTP wwwroot with HTTPS ALB**
```php
$CFG->wwwroot = 'http://elearning.tsin.ca';  // Should be https://
$CFG->sslproxy = true;
```

## Additional Resources

- [Moodle Reverse Proxy Documentation](https://docs.moodle.org/en/Reverse_proxy)
- [AWS ALB SSL Termination](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html)
- [Moodle Configuration Variables](https://docs.moodle.org/en/Configuration_file)

## Support

If you continue to experience issues after running the fix script:

1. Check the CloudWatch logs: `/aws/ec2/moodle`
2. Review Apache error logs on the instance: `/var/log/httpd/moodle_error.log`
3. Verify ALB listener configuration in AWS Console
4. Ensure ACM certificate is valid and attached to ALB HTTPS listener

## Script Locations

- PowerShell: `scripts/fix-redirect-loop.ps1`
- Bash: `scripts/fix-redirect-loop.sh`
- This documentation: `docs/REDIRECT-LOOP-FIX.md`

