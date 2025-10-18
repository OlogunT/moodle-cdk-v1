# HTTPS 501 Timeout Issue - Diagnosis & Available Scripts

## Problem Summary

**Symptom**: `https://elearning.tsin.ca` returns **501 timeout** error

**Status**: 
- ✅ HTTP works (returns 301 redirect)
- ❌ HTTPS fails (returns 501 timeout)
- ✅ Health endpoint works (HTTP 200)

---

## Root Cause Analysis

The 501 timeout on HTTPS suggests one of these issues:

### 1. **ALB HTTPS Listener Not Forwarding to Backend**
- ALB receives HTTPS request on port 443
- ALB should forward to backend on port 80
- Backend returns response
- But response is timing out

### 2. **Backend Not Responding to ALB Forwarded Requests**
- ALB forwards HTTPS traffic to backend HTTP
- Backend (Apache/PHP) not responding in time
- Timeout after 60 seconds

### 3. **Moodle Configuration Issue**
- `wwwroot` in config.php may be incorrect
- Redirect loop causing timeout
- SSL/reverse proxy settings misconfigured

### 4. **PHP-FPM Still Exhausted**
- PHP-FPM process pool still stuck
- Requests timing out

---

## Available Diagnostic Scripts

### 1. **verify-external-http.ps1** ⭐ START HERE
**Purpose**: Test HTTP/HTTPS from your local machine

**What it does**:
- Gets MoodleUrl from CloudFormation
- Tests `/health` endpoint
- Tests homepage with redirect following
- Detects redirect loops

**Run it**:
```powershell
./scripts/verify-external-http.ps1
```

**Expected output**:
```
MoodleUrl: https://elearning.tsin.ca
/health HTTP 200
/ HTTP 200 redirects=1 final=https://elearning.tsin.ca/
OK: HTTP works without redirect loop
```

---

### 2. **run-ssm-redirect-verify.ps1** ⭐ SECOND
**Purpose**: Test redirects from inside the instance

**What it does**:
- Finds a running instance
- Runs `ssm-verify-http-redirects.json` on it
- Tests localhost HTTP
- Tests ALB URL
- Compares results

**Run it**:
```powershell
./scripts/run-ssm-redirect-verify.ps1
```

**Expected output**:
```
InstanceId: i-0eab4573101db727a
CmdId: 12345678-1234-1234-1234-123456789012
Status: Success
LOCALHOST: 301 http://localhost/ 1
ALB:       301 https://elearning.tsin.ca/ 1
```

---

### 3. **ssm-verify-http-redirects.json** (Used by #2)
**Purpose**: SSM document that tests redirects

**Tests**:
- Localhost HTTP redirect
- ALB URL redirect
- Moodle config settings

**Key commands**:
```bash
curl -s -o /dev/null -w '%{http_code} %{url_effective} %{num_redirects}\n' http://localhost/
curl -sL --max-redirs 10 -o /dev/null -w '%{http_code} %{url_effective} %{num_redirects}\n' "$URL/"
grep -E 'wwwroot|reverseproxy|sslproxy|cookiesecure|loginhttps' /app/moodle/config.php
```

---

### 4. **ssm-verify-config-redirects.json** ⭐ DETAILED
**Purpose**: Deep dive into config and redirects

**Tests**:
- Config file order (important for reverse proxy)
- HTTP headers and redirects
- Moodle config settings

**Key checks**:
```bash
# Check config order
awk '/reverseproxy|sslproxy|cookiesecure|loginhttps|getremoteaddrconf|require_once.*lib\/setup\.php/'

# Check redirect headers
curl -sIL --max-redirs 10 "$URL/" | grep -E '^(HTTP/|Location:)'
```

---

### 5. **update-moodle-url.ps1** 🔧 FIX SCRIPT
**Purpose**: Update Moodle configuration with correct URL

**What it does**:
- Gets ALB URL from CloudFormation
- Finds all instances in ASG
- Updates `wwwroot` in config.php
- Clears Moodle cache
- Restarts Apache

**Run it**:
```powershell
./scripts/update-moodle-url.ps1 -StackName MoodleCdkStack -Region ca-central-1
```

**What it fixes**:
- Incorrect `wwwroot` setting
- Redirect loops
- SSL/HTTPS issues

---

## Recommended Diagnostic Sequence

### Step 1: Test from Local Machine
```powershell
./scripts/verify-external-http.ps1
```

**If it works**: Issue is intermittent or already fixed
**If it fails**: Continue to Step 2

---

### Step 2: Test from Instance
```powershell
./scripts/run-ssm-redirect-verify.ps1
```

**Compare results**:
- If localhost works but ALB fails → ALB/network issue
- If both fail → Instance/Moodle issue
- If both work → Intermittent issue

---

### Step 3: Deep Dive Config
```powershell
# Manually run the detailed check
$commands = @(
  "echo '=== CONFIG CHECK ==='",
  "grep -E 'wwwroot|reverseproxy|sslproxy|cookiesecure|loginhttps' /app/moodle/config.php",
  "echo '=== LOCALHOST TEST ==='",
  "curl -sIL --max-redirs 10 http://localhost/ | head -20",
  "echo '=== PHP-FPM STATUS ==='",
  "ps aux | grep php-fpm | grep -v grep | wc -l"
)
$cmdId = aws ssm send-command --instance-ids "i-0eab4573101db727a" --document-name "AWS-RunShellScript" --parameters "commands=$($commands | ConvertTo-Json)" --query "Command.CommandId" --output text
Start-Sleep -Seconds 10
aws ssm get-command-invocation --command-id $cmdId --instance-id "i-0eab4573101db727a" --output text
```

---

### Step 4: Fix Configuration
```powershell
./scripts/update-moodle-url.ps1
```

---

## Common Issues & Fixes

### Issue 1: Redirect Loop (10+ redirects)
**Cause**: `wwwroot` in config.php is wrong

**Fix**:
```powershell
./scripts/update-moodle-url.ps1
```

---

### Issue 2: 501 Bad Gateway
**Cause**: Backend not responding

**Possible fixes**:
1. Restart PHP-FPM
2. Check PHP-FPM process count
3. Check Apache error logs

**Commands**:
```bash
systemctl restart php-fpm
ps aux | grep php-fpm | grep -v grep | wc -l
tail -50 /var/log/httpd/error_log
```

---

### Issue 3: 504 Gateway Timeout
**Cause**: Backend taking too long to respond

**Possible fixes**:
1. Increase timeout in ALB
2. Optimize Moodle queries
3. Scale up instances

---

## Quick Diagnostic Commands

### Test Health Endpoint
```powershell
$lb = "Moodle-Moodl-JabjSDOCuhdn-677156032.ca-central-1.elb.amazonaws.com"
curl -s -o /dev/null -w "HTTP %{http_code}`n" "http://$lb/health"
```

### Test HTTP Redirect
```powershell
curl -s -i "http://$lb/" | Select-Object -First 10
```

### Test HTTPS (with -k to skip cert)
```powershell
curl -s -i -k "https://$lb/" | Select-Object -First 10
```

### Test Custom Domain
```powershell
curl -s -i -k "https://elearning.tsin.ca/" | Select-Object -First 10
```

### Check Instance Health
```powershell
aws elbv2 describe-target-health --target-group-arn (aws elbv2 describe-target-groups --names "Moodle-Moodl-DDVNNRQ6U8XD" --query "TargetGroups[0].TargetGroupArn" --output text) --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]" --output table
```

---

## Next Steps

1. **Run**: `./scripts/verify-external-http.ps1`
2. **If fails**: Run `./scripts/run-ssm-redirect-verify.ps1`
3. **If config issue**: Run `./scripts/update-moodle-url.ps1`
4. **If PHP-FPM issue**: Restart services on instances
5. **If still fails**: Check ALB listener configuration

---

## Success Criteria

✅ `https://elearning.tsin.ca/` returns HTTP 200
✅ Moodle homepage loads
✅ No redirect loops
✅ No timeout errors

