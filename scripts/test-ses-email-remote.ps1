#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test SES email delivery remotely from your local machine

.DESCRIPTION
    This script connects to Moodle instances via SSM and runs comprehensive
    email delivery tests. Run this AFTER deploying the SES configuration.

.PARAMETER Region
    AWS region (default: ca-central-1)

.PARAMETER StackName
    CloudFormation stack name (default: MoodleCdkStack)

.PARAMETER InstanceId
    Specific instance ID to test (optional, will auto-detect if not provided)

.PARAMETER SendTestEmail
    Send a test email to admin user (default: true)

.EXAMPLE
    # Test all instances
    .\test-ses-email-remote.ps1

.EXAMPLE
    # Test specific instance
    .\test-ses-email-remote.ps1 -InstanceId i-1234567890abcdef0

.EXAMPLE
    # Test without sending email
    .\test-ses-email-remote.ps1 -SendTestEmail:$false
#>

param(
    [string]$Region = "ca-central-1",
    [string]$StackName = "MoodleCdkStack",
    [string]$InstanceId = "",
    [bool]$SendTestEmail = $true
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "`n=== SES Email Delivery Test (Remote) ===" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor White
Write-Host "Stack: $StackName" -ForegroundColor White
Write-Host ""

# ============================================================================
# STEP 1: Find Moodle Instances
# ============================================================================
Write-Host "--- Step 1: Finding Moodle instances ---" -ForegroundColor Yellow

if ($InstanceId) {
    Write-Host "Using specified instance: $InstanceId" -ForegroundColor White
    $instances = @($InstanceId)
} else {
    Write-Host "Auto-detecting instances from stack..." -ForegroundColor Cyan
    
    $instancesJson = aws ec2 describe-instances `
        --filters "Name=tag:aws:cloudformation:stack-name,Values=$StackName" `
                  "Name=instance-state-name,Values=running" `
        --region $Region `
        --query "Reservations[*].Instances[*].InstanceId" `
        --output json
    
    $instances = ($instancesJson | ConvertFrom-Json) | ForEach-Object { $_ }
    
    if ($instances.Count -eq 0) {
        Write-Host "✗ No running instances found in stack: $StackName" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "✓ Found $($instances.Count) running instance(s)" -ForegroundColor Green
    foreach ($id in $instances) {
        Write-Host "  - $id" -ForegroundColor White
    }
}

Write-Host ""

# ============================================================================
# STEP 2: Upload Test Script to S3
# ============================================================================
Write-Host "--- Step 2: Uploading test script to S3 ---" -ForegroundColor Yellow

$accountId = aws sts get-caller-identity --query Account --output text
$bucketName = "moodle-scripts-$accountId-$Region"
$scriptPath = "scripts/test-ses-email-delivery.sh"

if (-not (Test-Path $scriptPath)) {
    Write-Host "✗ Test script not found: $scriptPath" -ForegroundColor Red
    exit 1
}

Write-Host "Uploading to s3://$bucketName/test-ses-email-delivery.sh" -ForegroundColor Cyan
aws s3 cp $scriptPath "s3://$bucketName/test-ses-email-delivery.sh" --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to upload test script" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Test script uploaded" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 3: Run Tests on Each Instance
# ============================================================================
Write-Host "--- Step 3: Running email delivery tests ---" -ForegroundColor Yellow

$testResults = @()

foreach ($instanceId in $instances) {
    Write-Host "`nTesting instance: $instanceId" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    
    # Download and execute test script
    $commands = @(
        "aws s3 cp s3://$bucketName/test-ses-email-delivery.sh /tmp/",
        "chmod +x /tmp/test-ses-email-delivery.sh",
        "/tmp/test-ses-email-delivery.sh"
    )
    
    $commandJson = $commands | ConvertTo-Json -Compress
    
    Write-Host "Sending command to instance..." -ForegroundColor Cyan
    $commandId = aws ssm send-command `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "commands=$commandJson" `
        --region $Region `
        --query "Command.CommandId" `
        --output text
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to send command to instance" -ForegroundColor Red
        $testResults += [PSCustomObject]@{
            InstanceId = $instanceId
            Status = "Failed"
            Error = "Could not send SSM command"
        }
        continue
    }
    
    Write-Host "Command ID: $commandId" -ForegroundColor White
    Write-Host "Waiting for command to complete..." -ForegroundColor Cyan
    
    # Wait for command to complete (max 2 minutes)
    $maxWait = 120
    $waited = 0
    $status = "Pending"
    
    while ($waited -lt $maxWait -and $status -in @("Pending", "InProgress")) {
        Start-Sleep -Seconds 5
        $waited += 5
        
        $statusJson = aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $instanceId `
            --region $Region `
            --query "Status" `
            --output text 2>$null
        
        if ($statusJson) {
            $status = $statusJson
        }
        
        Write-Host "." -NoNewline -ForegroundColor Gray
    }
    
    Write-Host ""
    
    # Get command output
    $outputJson = aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $instanceId `
        --region $Region `
        --output json
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to get command output" -ForegroundColor Red
        $testResults += [PSCustomObject]@{
            InstanceId = $instanceId
            Status = "Failed"
            Error = "Could not retrieve command output"
        }
        continue
    }
    
    $output = $outputJson | ConvertFrom-Json
    
    # Display output
    Write-Host "`nTest Output:" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host $output.StandardOutputContent -ForegroundColor White
    
    if ($output.StandardErrorContent) {
        Write-Host "`nErrors:" -ForegroundColor Yellow
        Write-Host $output.StandardErrorContent -ForegroundColor Yellow
    }
    
    # Parse test results
    $testsPassed = 0
    $testsFailed = 0
    
    if ($output.StandardOutputContent -match "Passed:\s+(\d+)") {
        $testsPassed = [int]$matches[1]
    }
    
    if ($output.StandardOutputContent -match "Failed:\s+(\d+)") {
        $testsFailed = [int]$matches[1]
    }
    
    $testResults += [PSCustomObject]@{
        InstanceId = $instanceId
        Status = $output.Status
        TestsPassed = $testsPassed
        TestsFailed = $testsFailed
        ExitCode = $output.ResponseCode
    }
    
    if ($output.Status -eq "Success" -and $testsFailed -eq 0) {
        Write-Host "`n✓ All tests passed on $instanceId" -ForegroundColor Green
    } else {
        Write-Host "`n⚠ Some tests failed on $instanceId" -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 4: Check SES Sending Statistics
# ============================================================================
Write-Host "`n--- Step 4: Checking SES sending statistics ---" -ForegroundColor Yellow

try {
    $sesQuota = aws ses get-send-quota --region $Region | ConvertFrom-Json
    
    Write-Host "SES Sending Quota:" -ForegroundColor Cyan
    Write-Host "  Max 24 Hour Send: $($sesQuota.Max24HourSend)" -ForegroundColor White
    Write-Host "  Max Send Rate: $($sesQuota.MaxSendRate)/sec" -ForegroundColor White
    Write-Host "  Sent Last 24 Hours: $($sesQuota.SentLast24Hours)" -ForegroundColor White
    
    if ($sesQuota.Max24HourSend -eq 200) {
        Write-Host "  ⚠ SES is in SANDBOX mode" -ForegroundColor Yellow
        Write-Host "  Request production access: https://console.aws.amazon.com/ses/home#/account" -ForegroundColor Yellow
    } else {
        Write-Host "  ✓ SES is in PRODUCTION mode" -ForegroundColor Green
    }
} catch {
    Write-Host "⚠ Could not retrieve SES quota: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""

# Check verified identities
try {
    $verifiedEmails = aws ses list-verified-email-addresses --region $Region | ConvertFrom-Json
    
    if ($verifiedEmails.VerifiedEmailAddresses.Count -gt 0) {
        Write-Host "Verified Email Addresses:" -ForegroundColor Cyan
        foreach ($email in $verifiedEmails.VerifiedEmailAddresses) {
            Write-Host "  ✓ $email" -ForegroundColor Green
        }
    } else {
        Write-Host "⚠ No verified email addresses found" -ForegroundColor Yellow
        Write-Host "  Verify: aws ses verify-email-identity --email-address your@email.com" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠ Could not retrieve verified emails: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# STEP 5: Summary
# ============================================================================
Write-Host "--- Step 5: Test Summary ---" -ForegroundColor Yellow

Write-Host "`nTest Results by Instance:" -ForegroundColor Cyan
$testResults | Format-Table -AutoSize

$totalPassed = ($testResults | Measure-Object -Property TestsPassed -Sum).Sum
$totalFailed = ($testResults | Measure-Object -Property TestsFailed -Sum).Sum
$successfulInstances = ($testResults | Where-Object { $_.Status -eq "Success" -and $_.TestsFailed -eq 0 }).Count

Write-Host "`nOverall Results:" -ForegroundColor Cyan
Write-Host "  Instances Tested: $($testResults.Count)" -ForegroundColor White
Write-Host "  Successful: $successfulInstances" -ForegroundColor Green
Write-Host "  Total Tests Passed: $totalPassed" -ForegroundColor Green
Write-Host "  Total Tests Failed: $totalFailed" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Red" })

Write-Host ""

if ($totalFailed -eq 0 -and $successfulInstances -eq $testResults.Count) {
    Write-Host "🎉 ALL TESTS PASSED!" -ForegroundColor Green
    Write-Host ""
    Write-Host "✅ SES email delivery is working correctly on all instances" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "1. Check your email inbox for test emails" -ForegroundColor White
    Write-Host "2. Monitor CloudWatch Logs: /aws/ec2/moodle" -ForegroundColor White
    Write-Host "3. Set up CloudWatch alarms for email bounces" -ForegroundColor White
    Write-Host "4. Request SES production access if needed" -ForegroundColor White
} else {
    Write-Host "⚠ SOME TESTS FAILED" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Cyan
    Write-Host "1. Run diagnostic: .\scripts\diagnose-ses-email.sh" -ForegroundColor White
    Write-Host "2. Check security group egress rules" -ForegroundColor White
    Write-Host "3. Verify VPC endpoint or NAT Gateway" -ForegroundColor White
    Write-Host "4. Check SMTP credentials in Secrets Manager" -ForegroundColor White
    Write-Host "5. Review Moodle error logs" -ForegroundColor White
}

Write-Host ""
Write-Host "=== Test Complete ===" -ForegroundColor Cyan
Write-Host ""

# Exit with error code if any tests failed
if ($totalFailed -gt 0) {
    exit 1
}

