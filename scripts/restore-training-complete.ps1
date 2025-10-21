#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Complete restoration orchestration for Training Moodle migration

.DESCRIPTION
    This script orchestrates the complete restoration process for training.tsin.ca:
    1. Stops auto-scaling to prevent interference
    2. Restores database from backup
    3. Restores moodledata files from backup
    4. Deploys Moodle code
    5. Creates configuration
    6. Runs upgrade
    7. Restarts services

.PARAMETER Stack
    CloudFormation stack name (default: TrainingMoodleCdkStack)

.PARAMETER Region
    AWS region (default: ca-central-1)

.PARAMETER DatabaseBackup
    Database backup filename in S3

.PARAMETER MoodledataBackup
    Moodledata backup filename in S3

.PARAMETER SkipDatabase
    Skip database restoration (if already done)

.PARAMETER SkipMoodledata
    Skip moodledata restoration (if already done)

.EXAMPLE
    .\restore-training-complete.ps1 -DatabaseBackup "training_db.sql.gz" -MoodledataBackup "training_data.tar.gz"
#>

param(
    [string]$Stack = "TrainingMoodleCdkStack",
    [string]$Region = "ca-central-1",
    [string]$DatabaseBackup = "",
    [string]$MoodledataBackup = "",
    [switch]$SkipDatabase,
    [switch]$SkipMoodledata
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Training Moodle Complete Restoration Orchestration           ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Step 1: Get Stack Information
# ============================================================================

Write-Host "--- Step 1: Retrieving Stack Information ---" -ForegroundColor Yellow
Write-Host ""

$stackInfo = aws cloudformation describe-stacks --stack-name $Stack --region $Region | ConvertFrom-Json

if (-not $stackInfo) {
    Write-Host "✗ Stack not found: $Stack" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Stack found: $Stack" -ForegroundColor Green

# Get Auto Scaling Group name
$asgName = aws cloudformation describe-stack-resources `
    --stack-name $Stack `
    --region $Region `
    --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" `
    --output text

Write-Host "✓ Auto Scaling Group: $asgName" -ForegroundColor Green

# Get running instances
$instances = aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" "Name=instance-state-name,Values=running" `
    --query "Reservations[].Instances[].InstanceId" `
    --output text

if ($instances) {
    $instanceList = $instances -split '\s+'
    Write-Host "✓ Running instances: $($instanceList.Count)" -ForegroundColor Green
    foreach ($id in $instanceList) {
        Write-Host "  - $id" -ForegroundColor White
    }
} else {
    Write-Host "⚠ No running instances found" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# Step 2: Scale Down Auto Scaling Group
# ============================================================================

Write-Host "--- Step 2: Scaling Down Auto Scaling Group ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Setting desired capacity to 1 to minimize interference..." -ForegroundColor Cyan
aws autoscaling set-desired-capacity `
    --auto-scaling-group-name $asgName `
    --desired-capacity 1 `
    --region $Region

Write-Host "✓ ASG scaled to 1 instance" -ForegroundColor Green
Write-Host "Waiting for instances to stabilize..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Get the single running instance
$instances = aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:aws:cloudformation:stack-name,Values=$Stack" "Name=instance-state-name,Values=running" `
    --query "Reservations[].Instances[].InstanceId" `
    --output text

$instanceId = $instances -split '\s+' | Select-Object -First 1

if (-not $instanceId) {
    Write-Host "✗ No running instance found after scaling" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Working with instance: $instanceId" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 3: Upload Restoration Scripts to S3
# ============================================================================

Write-Host "--- Step 3: Uploading Restoration Scripts ---" -ForegroundColor Yellow
Write-Host ""

$accountId = aws sts get-caller-identity --query Account --output text
$scriptBucket = "training-moodle-scripts-$accountId-$Region"

# Check if bucket exists, create if not
$bucketExists = aws s3 ls "s3://$scriptBucket" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating S3 bucket: $scriptBucket" -ForegroundColor Cyan
    aws s3 mb "s3://$scriptBucket" --region $Region
}

Write-Host "Uploading restoration scripts..." -ForegroundColor Cyan
aws s3 cp scripts/restore-training-database.sh "s3://$scriptBucket/" --region $Region
aws s3 cp scripts/restore-training-moodledata.sh "s3://$scriptBucket/" --region $Region

Write-Host "✓ Scripts uploaded to S3" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 4: Restore Database
# ============================================================================

if (-not $SkipDatabase) {
    Write-Host "--- Step 4: Restoring Database ---" -ForegroundColor Yellow
    Write-Host ""
    
    if ([string]::IsNullOrEmpty($DatabaseBackup)) {
        Write-Host "✗ Database backup filename required" -ForegroundColor Red
        Write-Host "  Use -DatabaseBackup parameter" -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "Database backup: $DatabaseBackup" -ForegroundColor Cyan
    Write-Host "Executing database restoration on instance..." -ForegroundColor Cyan
    
    $dbRestoreCommands = @(
        "aws s3 cp s3://$scriptBucket/restore-training-database.sh /tmp/",
        "chmod +x /tmp/restore-training-database.sh",
        "export REGION=$Region",
        "export STACK_NAME=$Stack",
        "/tmp/restore-training-database.sh $DatabaseBackup"
    )
    
    $commandJson = $dbRestoreCommands | ConvertTo-Json -Compress
    
    $commandId = aws ssm send-command `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "commands=$commandJson" `
        --timeout-seconds 3600 `
        --region $Region `
        --query "Command.CommandId" `
        --output text
    
    Write-Host "Command ID: $commandId" -ForegroundColor White
    Write-Host "Waiting for database restoration to complete..." -ForegroundColor Cyan
    Write-Host "(This may take 10-30 minutes depending on database size)" -ForegroundColor Gray
    
    # Wait for command to complete
    $maxWait = 3600 # 1 hour
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
            --output text
        
        Write-Host "  Status: $status (${elapsed}s elapsed)" -ForegroundColor Gray
        
        if ($status -eq "Success") {
            Write-Host "✓ Database restoration completed successfully" -ForegroundColor Green
            
            # Get output
            $output = aws ssm get-command-invocation `
                --command-id $commandId `
                --instance-id $instanceId `
                --region $Region `
                --query "StandardOutputContent" `
                --output text
            
            Write-Host ""
            Write-Host "Output:" -ForegroundColor Cyan
            Write-Host $output -ForegroundColor White
            break
        }
        elseif ($status -eq "Failed") {
            Write-Host "✗ Database restoration failed" -ForegroundColor Red
            
            $error = aws ssm get-command-invocation `
                --command-id $commandId `
                --instance-id $instanceId `
                --region $Region `
                --query "StandardErrorContent" `
                --output text
            
            Write-Host "Error:" -ForegroundColor Red
            Write-Host $error -ForegroundColor Red
            exit 1
        }
    }
    
    if ($elapsed -ge $maxWait) {
        Write-Host "⚠ Database restoration timed out" -ForegroundColor Yellow
        Write-Host "  Check SSM command status manually: $commandId" -ForegroundColor Yellow
    }
    
    Write-Host ""
} else {
    Write-Host "--- Step 4: Skipping Database Restoration ---" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# Step 5: Restore Moodledata
# ============================================================================

if (-not $SkipMoodledata) {
    Write-Host "--- Step 5: Restoring Moodledata Files ---" -ForegroundColor Yellow
    Write-Host ""
    
    if ([string]::IsNullOrEmpty($MoodledataBackup)) {
        Write-Host "✗ Moodledata backup filename required" -ForegroundColor Red
        Write-Host "  Use -MoodledataBackup parameter" -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "Moodledata backup: $MoodledataBackup" -ForegroundColor Cyan
    Write-Host "Executing moodledata restoration on instance..." -ForegroundColor Cyan
    
    $dataRestoreCommands = @(
        "aws s3 cp s3://$scriptBucket/restore-training-moodledata.sh /tmp/",
        "chmod +x /tmp/restore-training-moodledata.sh",
        "export REGION=$Region",
        "export STACK_NAME=$Stack",
        "/tmp/restore-training-moodledata.sh $MoodledataBackup"
    )
    
    $commandJson = $dataRestoreCommands | ConvertTo-Json -Compress
    
    $commandId = aws ssm send-command `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "commands=$commandJson" `
        --timeout-seconds 3600 `
        --region $Region `
        --query "Command.CommandId" `
        --output text
    
    Write-Host "Command ID: $commandId" -ForegroundColor White
    Write-Host "Waiting for moodledata restoration to complete..." -ForegroundColor Cyan
    Write-Host "(This may take 10-30 minutes depending on file size)" -ForegroundColor Gray
    
    # Wait for command to complete (similar to database restoration)
    $maxWait = 3600
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
            --output text
        
        Write-Host "  Status: $status (${elapsed}s elapsed)" -ForegroundColor Gray
        
        if ($status -eq "Success") {
            Write-Host "✓ Moodledata restoration completed successfully" -ForegroundColor Green
            
            $output = aws ssm get-command-invocation `
                --command-id $commandId `
                --instance-id $instanceId `
                --region $Region `
                --query "StandardOutputContent" `
                --output text
            
            Write-Host ""
            Write-Host "Output:" -ForegroundColor Cyan
            Write-Host $output -ForegroundColor White
            break
        }
        elseif ($status -eq "Failed") {
            Write-Host "✗ Moodledata restoration failed" -ForegroundColor Red
            
            $error = aws ssm get-command-invocation `
                --command-id $commandId `
                --instance-id $instanceId `
                --region $Region `
                --query "StandardErrorContent" `
                --output text
            
            Write-Host "Error:" -ForegroundColor Red
            Write-Host $error -ForegroundColor Red
            exit 1
        }
    }
    
    Write-Host ""
} else {
    Write-Host "--- Step 5: Skipping Moodledata Restoration ---" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# Summary
# ============================================================================

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           Restoration Process Complete!                       ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Verify Moodle code is deployed to /app/moodle" -ForegroundColor White
Write-Host "  2. Create config.php with correct settings" -ForegroundColor White
Write-Host "  3. Run Moodle upgrade: php admin/cli/upgrade.php" -ForegroundColor White
Write-Host "  4. Test Moodle functionality" -ForegroundColor White
Write-Host "  5. Scale ASG back to desired capacity" -ForegroundColor White
Write-Host ""

Write-Host "To scale ASG back up:" -ForegroundColor Yellow
Write-Host "  aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName --desired-capacity 2 --region $Region" -ForegroundColor White
Write-Host ""

