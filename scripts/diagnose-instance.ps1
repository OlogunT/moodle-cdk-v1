#!/usr/bin/env pwsh
param(
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Diagnosing Training Moodle Instance                         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Instance: $InstanceId" -ForegroundColor Gray
Write-Host ""

# Send diagnostic command
Write-Host "Sending diagnostic command..." -ForegroundColor Yellow

$diagnosticScript = @'
#!/bin/bash
echo "=== Instance Diagnostics ==="
echo ""
echo "--- EFS Mount Status ---"
mountpoint /app && echo "/app: MOUNTED" || echo "/app: NOT MOUNTED"
mountpoint /data && echo "/data: NOT MOUNTED" || echo "/data: NOT MOUNTED"
echo ""
echo "--- Disk Usage ---"
df -h
echo ""
echo "--- Mount Points ---"
mount | grep -E 'efs|nfs4'
echo ""
echo "--- EFS IDs from Environment ---"
env | grep EFS
echo ""
echo "--- Bootstrap Log (last 100 lines) ---"
tail -100 /var/log/bootstrap-moodle.log 2>/dev/null || echo "Bootstrap log not found"
echo ""
echo "--- User Data Log (last 50 lines) ---"
tail -50 /var/log/user-data.log 2>/dev/null || echo "User data log not found"
echo ""
echo "--- Check /data directory ---"
ls -la /data 2>/dev/null || echo "/data does not exist"
echo ""
echo "--- Check /app directory ---"
ls -la /app 2>/dev/null || echo "/app does not exist"
echo ""
echo "=== End Diagnostics ==="
'@

$commandId = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=$diagnosticScript" `
    --region $Region `
    --query "Command.CommandId" `
    --output text

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to send command" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Command sent: $commandId" -ForegroundColor Green
Write-Host "Waiting for results..." -ForegroundColor Yellow
Write-Host ""

# Wait for command to complete
Start-Sleep -Seconds 15

# Get results
$maxAttempts = 10
$attempt = 0

while ($attempt -lt $maxAttempts) {
    $attempt++
    
    $status = aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $InstanceId `
        --region $Region `
        --query "Status" `
        --output text 2>$null
    
    if ($status -eq "Success") {
        Write-Host "✓ Command completed successfully" -ForegroundColor Green
        Write-Host ""
        
        # Get output
        $output = aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $InstanceId `
            --region $Region `
            --query "StandardOutputContent" `
            --output text
        
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "Diagnostic Output:" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host $output
        Write-Host ""
        
        break
    }
    elseif ($status -eq "Failed") {
        Write-Host "✗ Command failed" -ForegroundColor Red
        
        $error = aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $InstanceId `
            --region $Region `
            --query "StandardErrorContent" `
            --output text
        
        if ($error) {
            Write-Host "Error:" -ForegroundColor Red
            Write-Host $error
        }
        
        break
    }
    elseif ($status -eq "InProgress" -or $status -eq "Pending") {
        Write-Host "Waiting... (attempt $attempt/$maxAttempts)" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
    else {
        Write-Host "Unknown status: $status" -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
}

if ($attempt -ge $maxAttempts) {
    Write-Host "⚠ Timeout waiting for command to complete" -ForegroundColor Yellow
    Write-Host "Command ID: $commandId" -ForegroundColor Gray
    Write-Host "Check manually with:" -ForegroundColor Gray
    Write-Host "  aws ssm get-command-invocation --command-id $commandId --instance-id $InstanceId --region $Region" -ForegroundColor White
}

