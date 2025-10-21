#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Resume download of moodledata file from SFTP using reget command

.DESCRIPTION
    This script uses sftp's reget command to resume an interrupted download
#>

param(
    [string]$BackupDir = "backups/training"
)

$ErrorActionPreference = "Stop"

# Configuration
$sftpHost = "sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
$sftpUser = "etraintouchstone"
$keyFile = "source/etraintouchstone"
$dataFile = "etraintouchstone-learn-moodledata.tar.gz"
$expectedSizeGB = 68.9

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Resume Moodledata Download from SFTP                        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Create backup directory
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
}

$localPath = Join-Path $BackupDir $dataFile

# Check current file size
if (Test-Path $localPath) {
    $currentSize = (Get-Item $localPath).Length / 1GB
    $progress = [math]::Round(($currentSize / $expectedSizeGB) * 100, 1)
    
    Write-Host "Current Status:" -ForegroundColor Yellow
    Write-Host "  File: $localPath" -ForegroundColor White
    Write-Host "  Downloaded: $([math]::Round($currentSize, 2)) GB / $expectedSizeGB GB" -ForegroundColor White
    Write-Host "  Progress: $progress%" -ForegroundColor White
    Write-Host ""
    
    if ($currentSize -ge $expectedSizeGB) {
        Write-Host "✓ File appears to be complete!" -ForegroundColor Green
        Write-Host ""
        $confirm = Read-Host "Re-download anyway? (y/n)"
        if ($confirm -ne 'y') {
            Write-Host "Download cancelled" -ForegroundColor Yellow
            exit 0
        }
        Remove-Item $localPath -Force
    }
} else {
    Write-Host "No existing file found. Starting fresh download..." -ForegroundColor Yellow
    Write-Host ""
}

# Create SFTP script with reget command (resume download)
$sftpScript = @"
reget $dataFile $localPath
bye
"@

$scriptFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $scriptFile -Value $sftpScript

try {
    Write-Host "Starting download (with resume support)..." -ForegroundColor Cyan
    Write-Host "  Remote: $dataFile" -ForegroundColor White
    Write-Host "  Local:  $localPath" -ForegroundColor White
    Write-Host ""
    Write-Host "This will take a while (68.9 GB file)..." -ForegroundColor Yellow
    Write-Host "Press Ctrl+C to pause. Run this script again to resume." -ForegroundColor Yellow
    Write-Host ""
    
    $startTime = Get-Date
    
    # Use sftp with reget for resume support
    sftp -i $keyFile -o StrictHostKeyChecking=no -b $scriptFile "$sftpUser@$sftpHost"
    
    if ($LASTEXITCODE -eq 0 -and (Test-Path $localPath)) {
        $endTime = Get-Date
        $duration = $endTime - $startTime
        $fileSize = (Get-Item $localPath).Length / 1GB
        
        Write-Host ""
        Write-Host "✓ Download complete!" -ForegroundColor Green
        Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
        Write-Host "  File size: $([math]::Round($fileSize, 2)) GB" -ForegroundColor Green
        Write-Host ""
        
        # Verify size
        if ($fileSize -lt ($expectedSizeGB * 0.95)) {
            Write-Host "⚠ Warning: File size is smaller than expected!" -ForegroundColor Yellow
            Write-Host "  Expected: ~$expectedSizeGB GB" -ForegroundColor Yellow
            Write-Host "  Got: $([math]::Round($fileSize, 2)) GB" -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "✗ Download failed or was interrupted" -ForegroundColor Red
        Write-Host "  Run this script again to resume the download" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}
finally {
    Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Next step: Run the full download script to get remaining files and upload to S3" -ForegroundColor Cyan
Write-Host "  pwsh scripts/download-training-backup-simple.ps1" -ForegroundColor White
Write-Host ""

