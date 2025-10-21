#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Simple script to download Training Moodle backup files from SFTP and upload to S3

.DESCRIPTION
    Downloads the backup files using OpenSSH sftp and uploads them to S3 bucket
#>

param(
    [string]$BackupDir = "backups/training",
    [string]$Region = "ca-central-1"
)

$ErrorActionPreference = "Stop"

# Configuration
$sftpHost = "sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
$sftpUser = "etraintouchstone"
$keyFile = "source/etraintouchstone"
$dbFile = "mdl_etraintouchstone.sql"
$dataFile = "etraintouchstone-learn-moodledata.tar.gz"
$appFile = "etraintouchstone-learn-app.tar.gz"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Training Moodle Backup Download & S3 Upload                 ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Create backup directory
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
}

Write-Host "Backup Directory: $BackupDir" -ForegroundColor Cyan
Write-Host ""

# Get S3 bucket name from CloudFormation stack outputs
Write-Host "--- Getting S3 Bucket Name from Stack Outputs ---" -ForegroundColor Yellow
$stackOutputs = aws cloudformation describe-stacks --stack-name TrainingMoodleCdkStack --region $Region --query "Stacks[0].Outputs" --output json | ConvertFrom-Json
$s3Bucket = ($stackOutputs | Where-Object { $_.OutputKey -eq "TrainingScriptsBucket" }).OutputValue

if (-not $s3Bucket) {
    Write-Host "✗ Could not find S3 bucket from stack outputs" -ForegroundColor Red
    exit 1
}

Write-Host "✓ S3 Bucket: $s3Bucket" -ForegroundColor Green
Write-Host ""

# Download files
Write-Host "--- Downloading Backup Files from SFTP ---" -ForegroundColor Yellow
Write-Host ""

$filesToDownload = @(
    @{Name = "Database"; File = $dbFile; Size = "197 MB"},
    @{Name = "Moodledata"; File = $dataFile; Size = "68.9 GB"},
    @{Name = "App Code"; File = $appFile; Size = "84.3 MB"}
)

foreach ($item in $filesToDownload) {
    $localPath = Join-Path $BackupDir $item.File
    
    Write-Host "Downloading: $($item.Name) ($($item.Size))" -ForegroundColor Cyan
    Write-Host "  Remote: $($item.File)" -ForegroundColor White
    Write-Host "  Local:  $localPath" -ForegroundColor White
    
    # Check if file already exists
    if (Test-Path $localPath) {
        Write-Host "  ⚠ File already exists locally, skipping download" -ForegroundColor Yellow
        Write-Host ""
        continue
    }
    
    # Create SFTP batch script
    $batchScript = @"
get $($item.File) $localPath
bye
"@
    
    $batchFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $batchFile -Value $batchScript
    
    try {
        Write-Host "  Starting download..." -ForegroundColor White
        $startTime = Get-Date
        
        # Use sftp with batch mode
        sftp -i $keyFile -o StrictHostKeyChecking=no -b $batchFile "$sftpUser@$sftpHost" 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0 -and (Test-Path $localPath)) {
            $endTime = Get-Date
            $duration = $endTime - $startTime
            $fileSize = (Get-Item $localPath).Length / 1GB
            
            Write-Host "  ✓ Download complete in $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
            Write-Host "  ✓ File size: $([math]::Round($fileSize, 2)) GB" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Download failed" -ForegroundColor Red
            exit 1
        }
    }
    finally {
        Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
    }
    
    Write-Host ""
}

Write-Host "--- Uploading Files to S3 ---" -ForegroundColor Yellow
Write-Host ""

foreach ($item in $filesToDownload) {
    $localPath = Join-Path $BackupDir $item.File
    
    if (-not (Test-Path $localPath)) {
        Write-Host "⚠ Skipping $($item.Name) - file not found locally" -ForegroundColor Yellow
        continue
    }
    
    Write-Host "Uploading: $($item.Name)" -ForegroundColor Cyan
    Write-Host "  Local:  $localPath" -ForegroundColor White
    Write-Host "  S3:     s3://$s3Bucket/$($item.File)" -ForegroundColor White
    
    # Check if file already exists in S3
    $s3Check = aws s3 ls "s3://$s3Bucket/$($item.File)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ⚠ File already exists in S3, skipping upload" -ForegroundColor Yellow
        Write-Host ""
        continue
    }
    
    Write-Host "  Starting upload..." -ForegroundColor White
    $startTime = Get-Date
    
    # Upload to S3 with progress
    aws s3 cp $localPath "s3://$s3Bucket/$($item.File)" --region $Region
    
    if ($LASTEXITCODE -eq 0) {
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        Write-Host "  ✓ Upload complete in $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Upload failed" -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
}

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   Phase 3 Complete: All Backup Files Downloaded & Uploaded    ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Proceed to Phase 4: Restore Database and Files" -ForegroundColor White
Write-Host "  2. Run: pwsh scripts/restore-training-complete.ps1" -ForegroundColor White
Write-Host ""

