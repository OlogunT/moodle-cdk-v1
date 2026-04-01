#!/usr/bin/env pwsh
param(
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Fix EFS Mounts and Download Training Backups                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Get S3 bucket name
Write-Host "Getting S3 bucket name..." -ForegroundColor Cyan
$s3Bucket = "training-moodle-scripts-483382415631-ca-central-1"
Write-Host "✓ S3 Bucket: $s3Bucket" -ForegroundColor Green
Write-Host ""

# Read and prepare the bash script
Write-Host "Preparing fix script..." -ForegroundColor Cyan
$bashScript = Get-Content "scripts/fix-efs-and-download.sh" -Raw
$bashScript = $bashScript -replace "__S3_BUCKET__", $s3Bucket

# Upload script to S3
Write-Host "Uploading script to S3..." -ForegroundColor Cyan
$scriptFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $scriptFile -Value $bashScript -NoNewline
aws s3 cp $scriptFile "s3://$s3Bucket/scripts/fix-efs-and-download.sh" --region $Region
Remove-Item $scriptFile -Force

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to upload script" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Script uploaded" -ForegroundColor Green
Write-Host ""

# Execute via SSM
Write-Host "Executing fix and download on instance $InstanceId..." -ForegroundColor Cyan
Write-Host ""
Write-Host "This will:" -ForegroundColor Yellow
Write-Host "  1. Check and fix EFS mounts" -ForegroundColor Yellow
Write-Host "  2. Download all 3 backup files (197 MB + 84 MB + 68.9 GB)" -ForegroundColor Yellow
Write-Host "  3. Store files on EFS at /data/training-backups/" -ForegroundColor Yellow
Write-Host ""
Write-Host "Estimated time: 1-2 hours for the large moodledata file" -ForegroundColor Yellow
Write-Host ""

# Create SSM command
$ssmCommands = @(
    "aws s3 cp s3://$s3Bucket/scripts/fix-efs-and-download.sh /tmp/fix-efs-and-download.sh --region $Region",
    "chmod +x /tmp/fix-efs-and-download.sh",
    "/tmp/fix-efs-and-download.sh 2>&1 | tee /tmp/fix-efs-download.log"
)

$commandJson = @{
    commands = $ssmCommands
} | ConvertTo-Json

$commandFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $commandFile -Value $commandJson -NoNewline

try {
    $result = aws ssm send-command `
        --instance-ids $InstanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "file://$commandFile" `
        --region $Region `
        --output json | ConvertFrom-Json
    
    $commandId = $result.Command.CommandId
    
    Write-Host "✓ Command sent successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Command ID: $commandId" -ForegroundColor Cyan
    Write-Host ""
    
    # Wait a bit for command to start
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
            $invocation = aws ssm get-command-invocation `
                --command-id $commandId `
                --instance-id $InstanceId `
                --region $Region `
                --output json 2>$null | ConvertFrom-Json
            
            $status = $invocation.Status
            $timestamp = Get-Date -Format "HH:mm:ss"
            
            if ($status -eq "Success") {
                Write-Host ""
                Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
                Write-Host "✅ FIX AND DOWNLOAD COMPLETED SUCCESSFULLY!" -ForegroundColor Green
                Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
                Write-Host ""
                Write-Host "Total Time: $elapsedStr" -ForegroundColor Green
                Write-Host ""
                
                # Show last part of output
                if ($invocation.StandardOutputContent) {
                    Write-Host "━━━ Final Output (last 50 lines) ━━━" -ForegroundColor Cyan
                    $lines = $invocation.StandardOutputContent -split "`n"
                    $startLine = [Math]::Max(0, $lines.Count - 50)
                    $lines[$startLine..($lines.Count-1)] | ForEach-Object { Write-Host $_ }
                }
                
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
                Write-Host "✗ COMMAND FAILED!" -ForegroundColor Red
                Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
                Write-Host ""
                
                if ($invocation.StandardOutputContent) {
                    Write-Host "━━━ Output (last 50 lines) ━━━" -ForegroundColor Yellow
                    $lines = $invocation.StandardOutputContent -split "`n"
                    $startLine = [Math]::Max(0, $lines.Count - 50)
                    $lines[$startLine..($lines.Count-1)] | ForEach-Object { Write-Host $_ }
                }
                
                if ($invocation.StandardErrorContent) {
                    Write-Host ""
                    Write-Host "━━━ Error Output ━━━" -ForegroundColor Red
                    Write-Host $invocation.StandardErrorContent
                }
                
                break
            }
            elseif ($status -eq "InProgress") {
                Write-Host "[$timestamp] Elapsed: $elapsedStr | Check #$iteration | Status: InProgress" -ForegroundColor Yellow
                
                # Show snippet of current output every 5 iterations
                if ($iteration % 5 -eq 0 -and $invocation.StandardOutputContent) {
                    $lines = $invocation.StandardOutputContent -split "`n"
                    $lastLine = $lines | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1
                    if ($lastLine) {
                        Write-Host "  Latest: $lastLine" -ForegroundColor Gray
                    }
                }
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
    Write-Host ""
    Write-Host "To check logs on the instance:" -ForegroundColor Gray
    Write-Host "  cat /tmp/fix-efs-download.log" -ForegroundColor White
    
} finally {
    Remove-Item $commandFile -Force -ErrorAction SilentlyContinue
}

