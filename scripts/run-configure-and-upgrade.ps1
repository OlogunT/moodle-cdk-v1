#!/usr/bin/env pwsh

param(
    [string]$Region = "ca-central-1",
    [string]$InstanceId = "i-06e7f96652b2b9620"
)

$ErrorActionPreference = 'Stop'

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Phase 5: Configure & Upgrade Training Moodle               ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Get S3 bucket name
$s3Bucket = "training-moodle-scripts-483382415631-ca-central-1"
Write-Host "S3 Bucket: $s3Bucket" -ForegroundColor White
Write-Host ""

# Upload script to S3
Write-Host "Uploading configuration script to S3..." -ForegroundColor Cyan
aws s3 cp scripts/configure-and-upgrade-training.sh s3://$s3Bucket/scripts/configure-and-upgrade-training.sh --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to upload script" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Script uploaded" -ForegroundColor Green
Write-Host ""

# Display what will happen
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host "⚠ This will perform the following actions:" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Create/update config.php with database credentials" -ForegroundColor Yellow
Write-Host "2. Set wwwroot to https://training.tsin.ca" -ForegroundColor Yellow
Write-Host "3. Run Moodle upgrade (4.1 → 5.0 database schema)" -ForegroundColor Yellow
Write-Host "4. Purge all caches" -ForegroundColor Yellow
Write-Host "5. Re-enable email" -ForegroundColor Yellow
Write-Host ""
Write-Host "Estimated time: 10-20 minutes" -ForegroundColor Yellow
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Do you want to proceed? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Host "Aborted by user" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Starting configuration and upgrade on instance $InstanceId..." -ForegroundColor Cyan
Write-Host ""

# Create SSM command
$result = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=[aws s3 cp s3://$s3Bucket/scripts/configure-and-upgrade-training.sh /tmp/configure-and-upgrade.sh --region $Region,chmod +x /tmp/configure-and-upgrade.sh,/tmp/configure-and-upgrade.sh 2>&1 | tee /tmp/configure-upgrade.log]" `
    --region $Region `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to send SSM command" -ForegroundColor Red
    exit 1
}

$commandId = $result.Command.CommandId
Write-Host "✓ Configuration command sent successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Command ID: $commandId" -ForegroundColor Green
Write-Host ""

# Wait for command to start
Write-Host "Waiting for command to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

# Monitor progress
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Monitoring Progress (updates every 30 seconds)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press Ctrl+C to stop monitoring (upgrade will continue)" -ForegroundColor Gray
Write-Host ""

$startTime = Get-Date
$checkCount = 0

while ($true) {
    $checkCount++
    $elapsed = (Get-Date) - $startTime
    $elapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds
    
    # Get command status
    $status = aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $InstanceId `
        --region $Region `
        --query "Status" `
        --output text 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "⚠ Could not get command status, retrying..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        continue
    }
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] Elapsed: $elapsedStr | Check #$checkCount | Status: $status" -ForegroundColor Cyan
    
    if ($status -eq "Success" -or $status -eq "Failed" -or $status -eq "Cancelled" -or $status -eq "TimedOut") {
        break
    }
    
    Start-Sleep -Seconds 30
}

Write-Host ""

# Get final status
if ($status -eq "Success") {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "✅ CONFIGURATION & UPGRADE COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
} else {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    Write-Host "✗ CONFIGURATION & UPGRADE FAILED!" -ForegroundColor Red
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
}

Write-Host ""
Write-Host "Total Time: $elapsedStr" -ForegroundColor White
Write-Host ""

# Get output
Write-Host "Getting upgrade summary..." -ForegroundColor Cyan
Write-Host ""

try {
    $output = aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $InstanceId `
        --region $Region `
        --query "StandardOutputContent" `
        --output text 2>$null
    
    if ($output) {
        # Filter to show only the summary section
        $lines = $output -split "`n"
        $inSummary = $false
        foreach ($line in $lines) {
            if ($line -match "Phase 5 Complete" -or $line -match "Summary:") {
                $inSummary = $true
            }
            if ($inSummary) {
                Write-Host $line
            }
        }
    }
} catch {
    Write-Host "'charmap' codec can't encode characters in position X-Y: character maps to <undefined>" -ForegroundColor Yellow
    Write-Host "Full output saved to /tmp/configure-upgrade.log on instance" -ForegroundColor Yellow
}

Write-Host ""

if ($status -eq "Success") {
    Write-Host "✓ config.php created" -ForegroundColor Green
    Write-Host "✓ Database upgraded from Moodle 4.1 to 5.0" -ForegroundColor Green
    Write-Host "✓ Caches purged" -ForegroundColor Green
    Write-Host "✓ Email re-enabled" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next: Test the site at https://training.tsin.ca" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To view full upgrade log:" -ForegroundColor Gray
    Write-Host "  aws ssm send-command --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters 'commands=[cat /tmp/moodle-upgrade.log]' --region $Region" -ForegroundColor Gray
} else {
    Write-Host "Check logs on instance:" -ForegroundColor Yellow
    Write-Host "  /tmp/configure-upgrade.log" -ForegroundColor Yellow
    Write-Host "  /tmp/moodle-upgrade.log" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Monitoring complete." -ForegroundColor Cyan

