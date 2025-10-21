#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Verify that Training Moodle resources have BackupEnabled tags for AWS Backup
#>

Write-Host "=== Verifying Backup Tags on Training Moodle Resources ===" -ForegroundColor Cyan
Write-Host ""

# Get EFS filesystem IDs from stack outputs
$dataEfsId = "fs-0834ed0a16ccbb966"
$appEfsId = "fs-0f028c598179df080"

Write-Host "Checking Data EFS Filesystem Tags:" -ForegroundColor Yellow
aws efs describe-tags --file-system-id $dataEfsId --region ca-central-1 --query "Tags[?Key=='BackupEnabled']" --output table

Write-Host ""
Write-Host "Checking App EFS Filesystem Tags:" -ForegroundColor Yellow
aws efs describe-tags --file-system-id $appEfsId --region ca-central-1 --query "Tags[?Key=='BackupEnabled']" --output table

Write-Host ""
Write-Host "Checking RDS Database Tags:" -ForegroundColor Yellow
$dbArn = aws rds describe-db-instances --region ca-central-1 --query "DBInstances[?contains(DBInstanceIdentifier,'trainingmoodlecdkstack')].DBInstanceArn" --output text
if ($dbArn) {
    aws rds list-tags-for-resource --resource-name $dbArn --region ca-central-1 --query "TagList[?Key=='BackupEnabled']" --output table
} else {
    Write-Host "No Training Moodle RDS instance found" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Checking AWS Backup Configuration ===" -ForegroundColor Cyan
Write-Host ""

# Check if backup plan exists
$backupPlanId = aws backup list-backup-plans --region ca-central-1 --query "BackupPlansList[?BackupPlanName=='MoodleProductionBackupPlan'].BackupPlanId" --output text

if ($backupPlanId) {
    Write-Host "Backup Plan ID: $backupPlanId" -ForegroundColor Green
    Write-Host ""
    Write-Host "Backup Selections:" -ForegroundColor Yellow
    aws backup list-backup-selections --backup-plan-id $backupPlanId --region ca-central-1 --output table
    
    Write-Host ""
    Write-Host "Backup Plan Rules:" -ForegroundColor Yellow
    aws backup get-backup-plan --backup-plan-id $backupPlanId --region ca-central-1 --query "BackupPlan.Rules[*].[RuleName,ScheduleExpression,Lifecycle.DeleteAfterDays]" --output table
} else {
    Write-Host "WARNING: No backup plan found!" -ForegroundColor Red
    Write-Host "Please ensure MoodleBackupInfrastructureStack is deployed." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Training Moodle resources with BackupEnabled tag will be automatically backed up by AWS Backup" -ForegroundColor Green
Write-Host "Backup schedule: Hourly (RDS), Daily, Weekly, Monthly" -ForegroundColor Green
Write-Host "Retention: 7 days (hourly), 120 days (daily), 365 days (weekly), 7 years (monthly)" -ForegroundColor Green

