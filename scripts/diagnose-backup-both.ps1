#!/usr/bin/env pwsh
# Diagnose backup and copy issues on both elearning and training

$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "MOODLE BACKUP/COPY DIAGNOSTICS" -ForegroundColor Cyan
Write-Host "Running on both elearning and training" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Create output directory
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputDir = "scripts/outputs/backup-diagnostics-$timestamp"
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Host "Output directory: $outputDir" -ForegroundColor Green
Write-Host ""

# Run diagnostics on elearning
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host "1. ELEARNING.TSIN.CA" -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host ""

try {
    & "$PSScriptRoot/diagnose-backup-elearning.ps1" | Tee-Object -FilePath "$outputDir/elearning-diagnostics.txt"
} catch {
    Write-Host "[ERROR] Failed to diagnose elearning: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host ""

# Run diagnostics on training
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host "2. TRAINING.TSIN.CA" -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host ""

try {
    & "$PSScriptRoot/diagnose-backup-training.ps1" | Tee-Object -FilePath "$outputDir/training-diagnostics.txt"
} catch {
    Write-Host "[ERROR] Failed to diagnose training: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "DIAGNOSTICS COMPLETE" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Results saved to: $outputDir" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Review the diagnostic output above" -ForegroundColor White
Write-Host "2. Look for:" -ForegroundColor White
Write-Host "   - Stuck backup controllers (status != 1000)" -ForegroundColor White
Write-Host "   - Failed adhoc tasks" -ForegroundColor White
Write-Host "   - Disabled scheduled tasks" -ForegroundColor White
Write-Host "   - Cron not running" -ForegroundColor White
Write-Host "   - Database errors" -ForegroundColor White
Write-Host "   - Permission issues" -ForegroundColor White
Write-Host "3. If issues found, run fix script:" -ForegroundColor White
Write-Host "   ./scripts/fix-backup-elearning.ps1" -ForegroundColor Cyan
Write-Host "   ./scripts/fix-backup-training.ps1" -ForegroundColor Cyan
Write-Host ""

