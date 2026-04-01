#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Download Training Moodle backups directly to EC2 instance via SSM

.DESCRIPTION
    This script uses AWS Systems Manager to run commands on an EC2 instance
    to download backup files directly from SFTP, bypassing local machine
#>

param(
    [string]$Region = "ca-central-1"
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Download Training Backups Directly to EC2 Instance          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Get running instances
Write-Host "Finding Training Moodle EC2 instances..." -ForegroundColor Yellow
$instances = aws ec2 describe-instances `
    --filters "Name=tag:aws:cloudformation:stack-name,Values=TrainingMoodleCdkStack" "Name=instance-state-name,Values=running" `
    --query "Reservations[].Instances[].[InstanceId,PrivateIpAddress]" `
    --output json `
    --region $Region | ConvertFrom-Json

if ($instances.Count -eq 0) {
    Write-Host "✗ No running instances found" -ForegroundColor Red
    exit 1
}

$instanceId = $instances[0][0]
$instanceIp = $instances[0][1]

Write-Host "✓ Found instance: $instanceId ($instanceIp)" -ForegroundColor Green
Write-Host ""

# Upload SSH key to instance via S3
Write-Host "--- Step 1: Upload SSH Key to S3 ---" -ForegroundColor Yellow
$s3Bucket = (aws cloudformation describe-stacks --stack-name TrainingMoodleCdkStack --region $Region --query "Stacks[0].Outputs[?OutputKey=='TrainingScriptsBucket'].OutputValue" --output text)

Write-Host "Uploading SSH key to S3..." -ForegroundColor Cyan
aws s3 cp source/etraintouchstone "s3://$s3Bucket/keys/etraintouchstone" --region $Region

if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ SSH key uploaded" -ForegroundColor Green
} else {
    Write-Host "✗ Failed to upload SSH key" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Create SSM command to download backups
Write-Host "--- Step 2: Download Backups on EC2 Instance ---" -ForegroundColor Yellow
Write-Host ""

# Read bash script and replace placeholders
$bashScript = Get-Content "scripts/download-training-backup-on-ec2.sh" -Raw
$bashScript = $bashScript -replace "__S3_BUCKET__", $s3Bucket
$bashScript = $bashScript -replace "__REGION__", $Region

# Upload script to S3
Write-Host "Uploading download script to S3..." -ForegroundColor Cyan
$scriptFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $scriptFile -Value $bashScript -NoNewline
aws s3 cp $scriptFile "s3://$s3Bucket/scripts/download-backups.sh" --region $Region
Remove-Item $scriptFile -Force

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to upload script" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Script uploaded" -ForegroundColor Green
Write-Host ""

Write-Host "Executing download command on instance $instanceId..." -ForegroundColor Cyan
Write-Host "This will take 1-2 hours for the 68.9 GB moodledata file..." -ForegroundColor Yellow
Write-Host ""

# Execute via SSM - download and run script from S3
$ssmCommands = @(
    "aws s3 cp s3://$s3Bucket/scripts/download-backups.sh /tmp/download-backups.sh --region $Region",
    "chmod +x /tmp/download-backups.sh",
    "/tmp/download-backups.sh"
)

$commandId = aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=$($ssmCommands -join ',')" `
    --region $Region `
    --query "Command.CommandId" `
    --output text

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to send SSM command" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Command sent: $commandId" -ForegroundColor Green
Write-Host ""

Write-Host "Monitoring command execution..." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop monitoring (command will continue running)" -ForegroundColor Gray
Write-Host ""

# Monitor command execution
$maxWait = 7200  # 2 hours
$elapsed = 0
$interval = 30

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    
    $status = aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $instanceId `
        --region $Region `
        --query "Status" `
        --output text 2>$null
    
    if ($status -eq "Success") {
        Write-Host ""
        Write-Host "✅ Download completed successfully!" -ForegroundColor Green
        Write-Host ""
        
        # Get output
        Write-Host "Command Output:" -ForegroundColor Cyan
        aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $instanceId `
            --region $Region `
            --query "StandardOutputContent" `
            --output text
        
        Write-Host ""
        Write-Host "Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Restore database: Run restoration script" -ForegroundColor White
        Write-Host "  2. Restore moodledata: Extract to EFS" -ForegroundColor White
        Write-Host ""
        exit 0
    }
    elseif ($status -eq "Failed") {
        Write-Host ""
        Write-Host "✗ Download failed!" -ForegroundColor Red
        Write-Host ""
        
        # Get error output
        Write-Host "Error Output:" -ForegroundColor Red
        aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $instanceId `
            --region $Region `
            --query "StandardErrorContent" `
            --output text
        
        exit 1
    }
    elseif ($status -eq "InProgress" -or $status -eq "Pending") {
        $minutes = [math]::Floor($elapsed / 60)
        Write-Host "[$($minutes)m] Status: $status - Download in progress..." -ForegroundColor Yellow
    }
    else {
        Write-Host "Status: $status" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "⚠ Monitoring timeout reached (command may still be running)" -ForegroundColor Yellow
Write-Host "Check status with:" -ForegroundColor Cyan
Write-Host "  aws ssm get-command-invocation --command-id $commandId --instance-id $instanceId --region $Region" -ForegroundColor White
Write-Host ""

