# run-fix-lockfactory.ps1
# Run this script MANUALLY in a fresh PowerShell window if the agent terminal is broken.
#
# What it does:
#   1. Removes $CFG->lock_factory from config.php on the EFS writer instance (i-08cfb0d5a27e77adb)
#   2. Validates PHP syntax of config.php
#   3. Restarts php-fpm on BOTH instances to flush OPcache
#   4. Health-checks both instances
#
# Usage:
#   cd C:\github\moodle-cdk0
#   pwsh -NoProfile -File scripts/ops/run-fix-lockfactory.ps1

$profile   = "tsin-account"
$region    = "ca-central-1"
$instance1 = "i-08cfb0d5a27e77adb"   # EFS writer — do the file edit here
$instance2 = "i-00af3adb301e601f8"   # second instance — restart php-fpm only

Write-Host "`n=== STEP 1: Remove lock_factory from config.php (instance 1 / EFS) ===" -ForegroundColor Cyan

$fix = @"
cp /app/moodle/config.php /app/moodle/config.php.bak.lockfix.\$(date +%s) 2>/dev/null;
sed -i '/lock_factory/d' /app/moodle/config.php;
grep -n 'lock_factory' /app/moodle/config.php && echo STILL_PRESENT || echo REMOVED_OK;
php -l /app/moodle/config.php;
systemctl restart php-fpm && echo php-fpm-restarted;
sleep 3;
HTTP=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost/health 2>/dev/null || echo 000);
echo "Health-instance1:\$HTTP"
"@

$params = @{ commands = @($fix) } | ConvertTo-Json -Compress

$cmdId1 = aws --profile $profile --region $region ssm send-command `
    --document-name "AWS-RunShellScript" `
    --instance-ids $instance1 `
    --parameters $params `
    --timeout-seconds 120 `
    --query "Command.CommandId" --output text

if (-not $cmdId1) { Write-Error "Failed to send SSM command to instance 1"; exit 1 }
Write-Host "Command ID (instance 1): $cmdId1"
Write-Host "Waiting 30s for instance 1 command to complete..."
Start-Sleep -Seconds 30

$result1 = aws --profile $profile --region $region ssm get-command-invocation `
    --command-id $cmdId1 --instance-id $instance1 `
    --query "{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}" --output json | ConvertFrom-Json

Write-Host "Status: $($result1.Status)"
Write-Host $result1.Out
if ($result1.Err) { Write-Host "STDERR: $($result1.Err)" -ForegroundColor Yellow }

# ---- Step 2: Restart php-fpm on instance 2 (config.php is shared EFS) ----
Write-Host "`n=== STEP 2: Restart php-fpm on instance 2 (flush OPcache) ===" -ForegroundColor Cyan

$restart = @{ commands = @("systemctl restart php-fpm && echo php-fpm-restarted; sleep 3; HTTP=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost/health 2>/dev/null || echo 000); echo Health-instance2:\$HTTP") } | ConvertTo-Json -Compress

$cmdId2 = aws --profile $profile --region $region ssm send-command `
    --document-name "AWS-RunShellScript" `
    --instance-ids $instance2 `
    --parameters $restart `
    --timeout-seconds 60 `
    --query "Command.CommandId" --output text

if (-not $cmdId2) { Write-Error "Failed to send SSM command to instance 2"; exit 1 }
Write-Host "Command ID (instance 2): $cmdId2"
Write-Host "Waiting 20s..."
Start-Sleep -Seconds 20

$result2 = aws --profile $profile --region $region ssm get-command-invocation `
    --command-id $cmdId2 --instance-id $instance2 `
    --query "{Status:Status,Out:StandardOutputContent}" --output json | ConvertFrom-Json

Write-Host "Status: $($result2.Status)"
Write-Host $result2.Out

# ---- Final health check via ALB ----
Write-Host "`n=== STEP 3: ALB health check ===" -ForegroundColor Cyan
$http = (Invoke-WebRequest -Uri "https://elearning.tsin.ca/health" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue).StatusCode
Write-Host "elearning.tsin.ca/health → HTTP $http"
if ($http -eq 200) {
    Write-Host "`n✅ Fix complete — Moodle is healthy!" -ForegroundColor Green
} else {
    Write-Host "`n⚠ Site returned HTTP $http — check logs" -ForegroundColor Yellow
}

