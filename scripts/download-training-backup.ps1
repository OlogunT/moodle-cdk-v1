#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Download Moodle backup files from Lambda Solutions SFTP server for training.tsin.ca

.DESCRIPTION
    This script connects to the Lambda Solutions Cloud SFTP server and downloads
    the latest backup files (database dump and moodledata archive) for the
    training.tsin.ca Moodle instance.

.PARAMETER BackupDir
    Local directory to store downloaded backups (default: backups/training)

.PARAMETER UploadToS3
    Upload downloaded backups to S3 bucket after download

.PARAMETER S3Bucket
    S3 bucket name for backup storage (auto-detected if not specified)

.PARAMETER Region
    AWS region (default: ca-central-1)

.EXAMPLE
    .\download-training-backup.ps1
    
.EXAMPLE
    .\download-training-backup.ps1 -UploadToS3 -BackupDir "D:\backups\training"
#>

param(
    [string]$BackupDir = "backups/training",
    [switch]$UploadToS3,
    [string]$S3Bucket = "",
    [string]$Region = "ca-central-1"
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration
# ============================================================================

$sftpHost = "sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
$sftpUser = "etraintouchstone"
$keyFile = "source/etraintouchstone"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Training Moodle Backup Download from Lambda Solutions       ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Step 1: Verify Prerequisites
# ============================================================================

Write-Host "--- Step 1: Verifying Prerequisites ---" -ForegroundColor Yellow
Write-Host ""

# Check if SSH key exists
if (-not (Test-Path $keyFile)) {
    Write-Host "✗ SSH key file not found: $keyFile" -ForegroundColor Red
    Write-Host "  Please ensure the key file exists at the specified location." -ForegroundColor Red
    exit 1
}
Write-Host "✓ SSH key file found: $keyFile" -ForegroundColor Green

# Check for SFTP client (try multiple options)
$sftpClient = $null
$sftpCommand = $null

# Option 1: Check for psftp (PuTTY SFTP)
if (Get-Command psftp -ErrorAction SilentlyContinue) {
    $sftpClient = "psftp"
    Write-Host "✓ Found SFTP client: psftp (PuTTY)" -ForegroundColor Green
}
# Option 2: Check for sftp (OpenSSH)
elseif (Get-Command sftp -ErrorAction SilentlyContinue) {
    $sftpClient = "sftp"
    Write-Host "✓ Found SFTP client: sftp (OpenSSH)" -ForegroundColor Green
}
# Option 3: Check for WinSCP
elseif (Get-Command winscp.com -ErrorAction SilentlyContinue) {
    $sftpClient = "winscp"
    Write-Host "✓ Found SFTP client: WinSCP" -ForegroundColor Green
}
else {
    Write-Host "✗ No SFTP client found" -ForegroundColor Red
    Write-Host "  Please install one of the following:" -ForegroundColor Yellow
    Write-Host "  - OpenSSH (recommended): winget install Microsoft.OpenSSH.Beta" -ForegroundColor Yellow
    Write-Host "  - PuTTY: https://www.putty.org/" -ForegroundColor Yellow
    Write-Host "  - WinSCP: https://winscp.net/" -ForegroundColor Yellow
    exit 1
}

# Create backup directory
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Write-Host "✓ Created backup directory: $BackupDir" -ForegroundColor Green
} else {
    Write-Host "✓ Backup directory exists: $BackupDir" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# Step 2: Test SFTP Connection
# ============================================================================

Write-Host "--- Step 2: Testing SFTP Connection ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Connecting to: $sftpUser@$sftpHost" -ForegroundColor Cyan

# Create test connection script
$testScript = @"
ls
bye
"@

$testScriptFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $testScriptFile -Value $testScript

try {
    if ($sftpClient -eq "sftp") {
        # OpenSSH sftp
        $output = sftp -i $keyFile -b $testScriptFile "$sftpUser@$sftpHost" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ SFTP connection successful" -ForegroundColor Green
            Write-Host ""
            Write-Host "Available files on SFTP server:" -ForegroundColor Cyan
            Write-Host $output -ForegroundColor White
        } else {
            Write-Host "✗ SFTP connection failed" -ForegroundColor Red
            Write-Host $output -ForegroundColor Red
            exit 1
        }
    }
    elseif ($sftpClient -eq "psftp") {
        # PuTTY psftp
        $output = psftp -i $keyFile -b $testScriptFile "$sftpUser@$sftpHost" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ SFTP connection successful" -ForegroundColor Green
            Write-Host ""
            Write-Host "Available files on SFTP server:" -ForegroundColor Cyan
            Write-Host $output -ForegroundColor White
        } else {
            Write-Host "✗ SFTP connection failed" -ForegroundColor Red
            Write-Host $output -ForegroundColor Red
            exit 1
        }
    }
    elseif ($sftpClient -eq "winscp") {
        # WinSCP
        Write-Host "⚠ WinSCP detected - please use GUI to download files" -ForegroundColor Yellow
        Write-Host "  Connection details:" -ForegroundColor Cyan
        Write-Host "  Host: $sftpHost" -ForegroundColor White
        Write-Host "  User: $sftpUser" -ForegroundColor White
        Write-Host "  Key:  $keyFile" -ForegroundColor White
        exit 0
    }
}
finally {
    Remove-Item $testScriptFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ============================================================================
# Step 3: List and Select Backup Files
# ============================================================================

Write-Host "--- Step 3: Identifying Backup Files ---" -ForegroundColor Yellow
Write-Host ""

Write-Host "Please review the file list above and identify:" -ForegroundColor Cyan
Write-Host "  1. Database backup file (usually .sql or .sql.gz)" -ForegroundColor White
Write-Host "  2. Moodledata archive (usually .tar.gz or .zip)" -ForegroundColor White
Write-Host ""

$dbFile = Read-Host "Enter database backup filename"
$dataFile = Read-Host "Enter moodledata archive filename"

Write-Host ""
Write-Host "Selected files:" -ForegroundColor Cyan
Write-Host "  Database:   $dbFile" -ForegroundColor White
Write-Host "  Moodledata: $dataFile" -ForegroundColor White
Write-Host ""

$confirm = Read-Host "Proceed with download? (y/n)"
if ($confirm -ne 'y') {
    Write-Host "Download cancelled by user" -ForegroundColor Yellow
    exit 0
}

Write-Host ""

# ============================================================================
# Step 4: Download Backup Files
# ============================================================================

Write-Host "--- Step 4: Downloading Backup Files ---" -ForegroundColor Yellow
Write-Host ""

# Create download script
$downloadScript = @"
get $dbFile $BackupDir/$dbFile
get $dataFile $BackupDir/$dataFile
bye
"@

$downloadScriptFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $downloadScriptFile -Value $downloadScript

try {
    Write-Host "Downloading files..." -ForegroundColor Cyan
    Write-Host "  This may take several minutes depending on file sizes..." -ForegroundColor Gray
    Write-Host ""
    
    if ($sftpClient -eq "sftp") {
        sftp -i $keyFile -b $downloadScriptFile "$sftpUser@$sftpHost"
    }
    elseif ($sftpClient -eq "psftp") {
        psftp -i $keyFile -b $downloadScriptFile "$sftpUser@$sftpHost"
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Download completed successfully" -ForegroundColor Green
    } else {
        Write-Host "✗ Download failed" -ForegroundColor Red
        exit 1
    }
}
finally {
    Remove-Item $downloadScriptFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ============================================================================
# Step 5: Verify Downloaded Files
# ============================================================================

Write-Host "--- Step 5: Verifying Downloaded Files ---" -ForegroundColor Yellow
Write-Host ""

$dbFilePath = Join-Path $BackupDir $dbFile
$dataFilePath = Join-Path $BackupDir $dataFile

if (Test-Path $dbFilePath) {
    $dbSize = (Get-Item $dbFilePath).Length / 1MB
    Write-Host "✓ Database file: $dbFile ($([math]::Round($dbSize, 2)) MB)" -ForegroundColor Green
} else {
    Write-Host "✗ Database file not found: $dbFilePath" -ForegroundColor Red
}

if (Test-Path $dataFilePath) {
    $dataSize = (Get-Item $dataFilePath).Length / 1MB
    Write-Host "✓ Moodledata file: $dataFile ($([math]::Round($dataSize, 2)) MB)" -ForegroundColor Green
} else {
    Write-Host "✗ Moodledata file not found: $dataFilePath" -ForegroundColor Red
}

Write-Host ""

# ============================================================================
# Step 6: Upload to S3 (Optional)
# ============================================================================

if ($UploadToS3) {
    Write-Host "--- Step 6: Uploading to S3 ---" -ForegroundColor Yellow
    Write-Host ""
    
    # Auto-detect S3 bucket if not specified
    if ([string]::IsNullOrEmpty($S3Bucket)) {
        $accountId = aws sts get-caller-identity --query Account --output text
        $S3Bucket = "training-moodle-backups-$accountId-$Region"
        Write-Host "Auto-detected S3 bucket: $S3Bucket" -ForegroundColor Cyan
    }
    
    # Check if bucket exists, create if not
    $bucketExists = aws s3 ls "s3://$S3Bucket" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating S3 bucket: $S3Bucket" -ForegroundColor Cyan
        aws s3 mb "s3://$S3Bucket" --region $Region
        
        # Enable versioning and encryption
        aws s3api put-bucket-versioning --bucket $S3Bucket --versioning-configuration Status=Enabled --region $Region
        aws s3api put-bucket-encryption --bucket $S3Bucket --server-side-encryption-configuration '{
            "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
        }' --region $Region
        
        Write-Host "✓ S3 bucket created and configured" -ForegroundColor Green
    }
    
    # Upload database backup
    Write-Host "Uploading database backup to S3..." -ForegroundColor Cyan
    aws s3 cp $dbFilePath "s3://$S3Bucket/database/$dbFile" --region $Region
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Database backup uploaded" -ForegroundColor Green
    } else {
        Write-Host "✗ Database backup upload failed" -ForegroundColor Red
    }
    
    # Upload moodledata archive
    Write-Host "Uploading moodledata archive to S3..." -ForegroundColor Cyan
    aws s3 cp $dataFilePath "s3://$S3Bucket/moodledata/$dataFile" --region $Region
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Moodledata archive uploaded" -ForegroundColor Green
    } else {
        Write-Host "✗ Moodledata archive upload failed" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "S3 Backup Locations:" -ForegroundColor Cyan
    Write-Host "  Database:   s3://$S3Bucket/database/$dbFile" -ForegroundColor White
    Write-Host "  Moodledata: s3://$S3Bucket/moodledata/$dataFile" -ForegroundColor White
}

Write-Host ""

# ============================================================================
# Summary
# ============================================================================

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    Download Complete!                          ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Verify backup file integrity" -ForegroundColor White
Write-Host "  2. Deploy Training Moodle infrastructure (Phase 2)" -ForegroundColor White
Write-Host "  3. Run restoration scripts (Phase 4)" -ForegroundColor White
Write-Host ""

Write-Host "Local Backup Location: $BackupDir" -ForegroundColor Cyan
if ($UploadToS3) {
    Write-Host "S3 Backup Location: s3://$S3Bucket/" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "For next steps, see: TRAINING-MOODLE-MIGRATION-PLAN.md" -ForegroundColor Yellow
Write-Host ""

