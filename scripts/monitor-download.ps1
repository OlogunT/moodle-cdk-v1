#!/usr/bin/env pwsh
param(
    [string]$CommandId = "e7a2774e-32c6-4061-bd2d-0341233ffe5a",
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Monitoring Training Backup Download to EFS                  ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Command ID: $CommandId" -ForegroundColor Gray
Write-Host "Instance: $InstanceId" -ForegroundColor Gray
Write-Host "Download Location: /data/training-backups/ (EFS)" -ForegroundColor Gray
Write-Host ""
Write-Host "Monitoring every 60 seconds..." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop monitoring (download will continue)" -ForegroundColor Gray
Write-Host ""

$iteration = 0
$startTime = Get-Date

while ($true) {
    $iteration++
    $elapsed = (Get-Date) - $startTime
    
    try {
        $status = aws ssm get-command-invocation `
            --command-id $CommandId `
            --instance-id $InstanceId `
            --region $Region `
            --query "Status" `
            --output text 2>&1
        
        $timestamp = Get-Date -Format "HH:mm:ss"
        $elapsedStr = "{0:D2}h {1:D2}m {2:D2}s" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds
        
        if ($status -match "Success") {
            Write-Host ""
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host "✅ DOWNLOAD COMPLETED SUCCESSFULLY!" -ForegroundColor Green
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host ""
            Write-Host "Total Time: $elapsedStr" -ForegroundColor Green
            Write-Host ""
            
            # Get final output
            Write-Host "Fetching final output..." -ForegroundColor Cyan
            $output = aws ssm get-command-invocation `
                --command-id $CommandId `
                --instance-id $InstanceId `
                --region $Region `
                --query "StandardOutputContent" `
                --output text 2>&1
            
            if ($output) {
                Write-Host ""
                Write-Host "━━━ Download Output ━━━" -ForegroundColor Cyan
                $output -split "`n" | Select-Object -Last 50 | ForEach-Object { Write-Host $_ }
            }
            
            Write-Host ""
            Write-Host "Files are ready in /data/training-backups/ on EFS" -ForegroundColor Green
            Write-Host ""
            Write-Host "Next: Proceed to Phase 4 - Restore Database and Files" -ForegroundColor Cyan
            break
        }
        elseif ($status -match "Failed") {
            Write-Host ""
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host "✗ DOWNLOAD FAILED!" -ForegroundColor Red
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host ""
            
            # Get error output
            $error = aws ssm get-command-invocation `
                --command-id $CommandId `
                --instance-id $InstanceId `
                --region $Region `
                --query "StandardErrorContent" `
                --output text 2>&1
            
            if ($error) {
                Write-Host "Error Output:" -ForegroundColor Red
                Write-Host $error -ForegroundColor Red
            }
            
            # Also get standard output for context
            $output = aws ssm get-command-invocation `
                --command-id $CommandId `
                --instance-id $InstanceId `
                --region $Region `
                --query "StandardOutputContent" `
                --output text 2>&1
            
            if ($output) {
                Write-Host ""
                Write-Host "Standard Output (last 30 lines):" -ForegroundColor Yellow
                $output -split "`n" | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
            }
            
            break
        }
        elseif ($status -match "InProgress") {
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

