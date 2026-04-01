#!/usr/bin/env pwsh
param(
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Phase 4: Restore Training Moodle Database and Files         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Get S3 bucket name
$s3Bucket = "training-moodle-scripts-483382415631-ca-central-1"
Write-Host "S3 Bucket: $s3Bucket" -ForegroundColor Green
Write-Host ""

# Upload script to S3
Write-Host "Uploading restoration script to S3..." -ForegroundColor Cyan
aws s3 cp "scripts/restore-training-moodle.sh" "s3://$s3Bucket/scripts/restore-training-moodle.sh" --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to upload script" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Script uploaded" -ForegroundColor Green
Write-Host ""

# Display what will happen
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host "⚠ WARNING: This will perform the following actions:" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. DROP and recreate the 'moodle' database in RDS" -ForegroundColor Yellow
Write-Host "2. Import database from mdl_etraintouchstone.sql (198 MB)" -ForegroundColor Yellow
Write-Host "3. Extract moodledata from etraintouchstone-learn-moodledata.tar.gz (69 GB)" -ForegroundColor Yellow
Write-Host "4. Set permissions (apache:apache, 777)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Estimated time: 15-25 minutes" -ForegroundColor Yellow
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Do you want to proceed? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Host "Restoration cancelled." -ForegroundColor Red
    exit 0
}

Write-Host ""
Write-Host "Starting restoration on instance $InstanceId..." -ForegroundColor Cyan
Write-Host ""

# Create SSM command
$result = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=[aws s3 cp s3://$s3Bucket/scripts/restore-training-moodle.sh /tmp/restore-training-moodle.sh --region $Region,chmod +x /tmp/restore-training-moodle.sh,/tmp/restore-training-moodle.sh 2>&1 | tee /tmp/restore.log]" `
    --region $Region `
    --output json | ConvertFrom-Json

$commandId = $result.Command.CommandId

Write-Host "✓ Restoration command sent successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Command ID: $commandId" -ForegroundColor Cyan
Write-Host ""

# Wait for command to start
Write-Host "Waiting for command to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Monitor progress
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Monitoring Progress (updates every 30 seconds)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press Ctrl+C to stop monitoring (restoration will continue)" -ForegroundColor Gray
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
            Write-Host "✅ RESTORATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host ""
            Write-Host "Total Time: $elapsedStr" -ForegroundColor Green
            Write-Host ""
            
            # Get the output
            Write-Host "Getting restoration summary..." -ForegroundColor Cyan
            Write-Host ""
            
            try {
                $output = aws ssm get-command-invocation `
                    --command-id $commandId `
                    --instance-id $InstanceId `
                    --region $Region `
                    --query "StandardOutputContent" `
                    --output text
                
                # Try to extract the summary section
                if ($output -match "(?s)Summary:.*?Ready for Phase 5") {
                    Write-Host $matches[0] -ForegroundColor White
                } else {
                    Write-Host "Full output saved to /tmp/restore.log on instance" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "Could not retrieve output (may be too large)" -ForegroundColor Yellow
                Write-Host "Check /tmp/restore.log on the instance for details" -ForegroundColor Yellow
            }
            
            Write-Host ""
            Write-Host "✓ Database restored to RDS" -ForegroundColor Green
            Write-Host "✓ Moodledata extracted to /data/moodledata/" -ForegroundColor Green
            Write-Host "✓ Permissions set (apache:apache)" -ForegroundColor Green
            Write-Host ""
            Write-Host "Next: Proceed to Phase 5 - Configuration & Testing" -ForegroundColor Cyan
            break
        }
        elseif ($status -eq "Failed") {
            Write-Host ""
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host "✗ RESTORATION FAILED!" -ForegroundColor Red
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host ""
            
            # Try to get error output
            try {
                $errorOutput = aws ssm get-command-invocation `
                    --command-id $commandId `
                    --instance-id $InstanceId `
                    --region $Region `
                    --query "StandardErrorContent" `
                    --output text
                
                if ($errorOutput) {
                    Write-Host "Error output:" -ForegroundColor Red
                    Write-Host $errorOutput -ForegroundColor Red
                }
            } catch {
                Write-Host "Could not retrieve error output" -ForegroundColor Red
            }
            
            Write-Host ""
            Write-Host "Check logs on instance: cat /tmp/restore.log" -ForegroundColor Yellow
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
    
    Start-Sleep -Seconds 30
}

Write-Host ""
Write-Host "Monitoring complete." -ForegroundColor Cyan

