# Redirect Loop Fix - Implementation Summary

## Date: 2025-10-18

## Issue Resolved
**ERR_TOO_MANY_REDIRECTS** - Moodle site at `https://elearning.tsin.ca` was experiencing infinite redirect loops

## Root Cause
The Moodle configuration had `$CFG->reverseproxy = true` which caused two problems:
1. **Direct blocking**: Moodle showed error "Reverse proxy enabled so the server cannot be accessed directly"
2. **Redirect loop**: When reverseproxy was removed but sslproxy was missing, Moodle couldn't recognize ALB's SSL termination

## Solution Applied
Updated Moodle configuration on both EC2 instances to:
- **Remove**: `$CFG->reverseproxy` (was set to `true`)
- **Remove**: `$CFG->getremoteaddrconf`, `$CFG->cookiesecure`, `$CFG->loginhttps`
- **Add**: `$CFG->sslproxy = true` (tells Moodle to trust X-Forwarded-Proto header from ALB)
- **Keep**: `$CFG->wwwroot = 'https://elearning.tsin.ca'`

## Files Changed

### 1. Fixed Scripts
- ✅ `scripts/intelligent-moodle-install.sh` - Updated `set_proxy_flags_in_config()` function
- ✅ `scripts/fix-redirect-loop.ps1` - New automated fix script (PowerShell)
- ✅ `scripts/fix-redirect-loop.sh` - New automated fix script (Bash)
- ✅ `docs/REDIRECT-LOOP-FIX.md` - Comprehensive documentation

### 2. Removed Obsolete Files
- ❌ `fix-complete-reverseproxy.json` - Had incorrect reverseproxy=true
- ❌ `fix-proxy-final.json` - Temporary fix file

### 3. Configuration Applied to Instances
Both instances (`i-0d1d83b141744d823` and `i-011c65cd247389ee6`) now have:
```php
$CFG->wwwroot = 'https://elearning.tsin.ca';
$CFG->sslproxy = true;
require_once(__DIR__ . "/lib/setup.php");
```

## Verification Results
✅ Health endpoint: HTTP 200 OK
✅ Login page loads successfully
✅ Moodle detected in page content
✅ No error pages
✅ No redirect loops (0-2 redirects, not 10+)

## Next Steps Required

### 1. Deploy Updated CDK Stack
The `intelligent-moodle-install.sh` script has been updated but needs to be deployed to S3:

```powershell
# Deploy the updated stack
cdk deploy --require-approval never
```

This will:
- Upload the fixed `intelligent-moodle-install.sh` to S3
- Ensure future instances get the correct configuration from the start

### 2. Optional: Rotate ASG Instances
To ensure all instances are running the latest configuration:

```powershell
# Start instance refresh to replace instances with new ones
./scripts/start-instance-refresh.ps1
```

**Note**: This is optional since we've already fixed the running instances manually.

### 3. Test After Deployment
After CDK deployment, verify the fix persists:

```bash
# Test the site
curl -sL https://elearning.tsin.ca/ | grep -i "log in"

# Check redirect count
curl -sL --max-redirs 20 -w "\nRedirects: %{num_redirects}\n" -o /dev/null https://elearning.tsin.ca/
```

## Prevention for Future Deployments

The updated `intelligent-moodle-install.sh` now includes:

```bash
# For HTTPS with ALB SSL termination:
# - sslproxy=true tells Moodle to trust X-Forwarded-Proto header from ALB
# - reverseproxy should NOT be set (setting it to true blocks direct access from ALB)
# - This prevents the "Reverse proxy enabled so the server cannot be accessed directly" error
# - This also prevents redirect loops (ERR_TOO_MANY_REDIRECTS)
if [ "$proto" = "https" ]; then
  sed -i "/require_once.*lib\/setup\.php/i \\\$CFG->sslproxy = true;" "$cfg"
  echo "✓ Set sslproxy=true for HTTPS ALB SSL termination"
fi
```

## Quick Fix Scripts Available

If the redirect loop occurs again, use these scripts:

### PowerShell (Windows/Cross-platform)
```powershell
./scripts/fix-redirect-loop.ps1
```

### Bash (Linux/Mac)
```bash
./scripts/fix-redirect-loop.sh
```

Both scripts:
- Automatically find all healthy instances
- Backup config.php before changes
- Apply the correct configuration
- Clear caches and restart services
- Verify the fix

## Technical Details

### ALB SSL Termination Flow
1. User → `https://elearning.tsin.ca/` (HTTPS)
2. ALB receives on port 443, terminates SSL
3. ALB forwards to backend on port 80 (HTTP)
4. ALB adds headers: `X-Forwarded-Proto: https`, `X-Forwarded-Port: 443`
5. Moodle with `$CFG->sslproxy = true` trusts these headers
6. Moodle recognizes the original request was HTTPS
7. No redirect loop occurs

### Why reverseproxy=true Caused Issues
When `$CFG->reverseproxy = true`:
- Moodle expects to be behind a reverse proxy
- Moodle blocks direct access with error message
- Even with proper headers, Moodle refuses to serve content
- This is a Moodle security feature to prevent misconfiguration

### Correct Configuration for ALB
For AWS ALB with SSL termination, only `$CFG->sslproxy = true` is needed:
- ✅ `$CFG->sslproxy = true` - Trust X-Forwarded-Proto
- ❌ `$CFG->reverseproxy` - Should NOT be set
- ❌ `$CFG->getremoteaddrconf` - Not needed for basic ALB setup
- ❌ `$CFG->cookiesecure` - Not needed (Moodle handles this automatically)
- ❌ `$CFG->loginhttps` - Not needed (deprecated in newer Moodle versions)

## References
- Documentation: `docs/REDIRECT-LOOP-FIX.md`
- Fix Scripts: `scripts/fix-redirect-loop.ps1`, `scripts/fix-redirect-loop.sh`
- Updated Installer: `scripts/intelligent-moodle-install.sh`
- Moodle Docs: https://docs.moodle.org/en/Reverse_proxy

## Status
🟢 **RESOLVED** - Site is now fully operational at https://elearning.tsin.ca/

## Action Items
- [ ] Deploy updated CDK stack to upload fixed scripts to S3
- [ ] (Optional) Rotate ASG instances to ensure all run latest configuration
- [ ] Monitor site for any recurrence of redirect issues

