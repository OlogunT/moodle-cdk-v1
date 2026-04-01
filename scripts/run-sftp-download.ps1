#!/usr/bin/env pwsh
param(
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Download Training Backups Using SFTP                        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Get S3 bucket name
$s3Bucket = "training-moodle-scripts-483382415631-ca-central-1"
Write-Host "S3 Bucket: $s3Bucket" -ForegroundColor Green
Write-Host ""

# Upload script to S3
Write-Host "Uploading SFTP download script to S3..." -ForegroundColor Cyan
aws s3 cp "scripts/download-with-sftp.sh" "s3://$s3Bucket/scripts/download-with-sftp.sh" --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to upload script" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Script uploaded" -ForegroundColor Green
Write-Host ""

# Execute via SSM
Write-Host "Executing SFTP download on instance $InstanceId..." -ForegroundColor Cyan
Write-Host ""
Write-Host "This will download:" -ForegroundColor Yellow
Write-Host "  1. mdl_etraintouchstone.sql (197 MB)" -ForegroundColor Yellow
Write-Host "  2. etraintouchstone-learn-app.tar.gz (84.3 MB)" -ForegroundColor Yellow
Write-Host "  3. etraintouchstone-learn-moodledata.tar.gz (68.9 GB)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Estimated time: 1-2 hours for the large file" -ForegroundColor Yellow
Write-Host ""

# Create SSM command
$result = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=[aws s3 cp s3://$s3Bucket/scripts/download-with-sftp.sh /tmp/download-with-sftp.sh --region $Region,chmod +x /tmp/download-with-sftp.sh,/tmp/download-with-sftp.sh 2>&1 | tee /tmp/sftp-download.log]" `
    --region $Region `
    --output json | ConvertFrom-Json

$commandId = $result.Command.CommandId

Write-Host "✓ Command sent successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Command ID: $commandId" -ForegroundColor Cyan
Write-Host ""

# Wait for command to start
Write-Host "Waiting for command to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Monitor progress
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Monitoring Progress (updates every 60 seconds)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press Ctrl+C to stop monitoring (download will continue)" -ForegroundColor Gray
Write-Host ""

$iteration = 0
$startTime = Get-Date

while ($true) {
    $iteration++
    $elapsed = (Get-Date) - $startTime
    $elapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds
    
    try {
        $status = aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $InstanceId `
            --region $Region `
            --query "Status" `
            --output text 2>$null
        
        $timestamp = Get-Date -Format "HH:mm:ss"
        
        if ($status -eq "Success") {
            Write-Host ""
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host "✅ DOWNLOAD COMPLETED SUCCESSFULLY!" -ForegroundColor Green
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host ""
            Write-Host "Total Time: $elapsedStr" -ForegroundColor Green
            Write-Host ""
            Write-Host "✓ Files are ready in /data/training-backups/ on EFS" -ForegroundColor Green
            Write-Host "✓ Files are accessible from both EC2 instances" -ForegroundColor Green
            Write-Host ""
            Write-Host "Next: Proceed to Phase 4 - Restore Database and Files" -ForegroundColor Cyan
            break
        }
        elseif ($status -eq "Failed") {
            Write-Host ""
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host "✗ DOWNLOAD FAILED!" -ForegroundColor Red
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host ""
            Write-Host "Check logs on instance: cat /tmp/sftp-download.log" -ForegroundColor Yellow
            break
        }
        elseif ($status -eq "InProgress") {
            Write-Host "[$timestamp] Elapsed: $elapsedStr | Check #$iteration | Status: InProgress" -ForegroundColor Yellow
        }
        else {
            Write-Host "[$timestamp] Elapsed: $elapsedStr | Check #$iteration | Status: $status" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "[$timestamp] Error checking status: $_" -ForegroundColor Red
    }
    
    Start-Sleep -Seconds 60
}

Write-Host ""
Write-Host "Monitoring complete." -ForegroundColor Cyan

