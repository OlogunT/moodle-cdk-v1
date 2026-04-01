#!/usr/bin/env pwsh

param(
    [string]$CommandId = "b5b56b6d-3e22-47fe-b600-4f7c73c93f0f",
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Moodledata Extraction Status                               ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Command ID: $CommandId" -ForegroundColor White
Write-Host "Instance ID: $InstanceId" -ForegroundColor White
Write-Host ""

$status = aws ssm get-command-invocation --command-id $CommandId --instance-id $InstanceId --region $Region --query "Status" --output text 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Could not get command status" -ForegroundColor Red
    exit 1
}

Write-Host "Status: $status" -ForegroundColor Yellow
Write-Host ""

if ($status -eq "InProgress") {
    Write-Host "⏳ Extraction is still running..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This will take 10-20 minutes for the 69 GB archive" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To check again, run:" -ForegroundColor Gray
    Write-Host "  pwsh scripts/check-extraction-status.ps1" -ForegroundColor Gray
    
} elseif ($status -eq "Success") {
    Write-Host "✅ EXTRACTION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Output:" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    $output = aws ssm get-command-invocation --command-id $CommandId --instance-id $InstanceId --region $Region --query "StandardOutputContent" --output text 2>$null
    Write-Host $output
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
} elseif ($status -eq "Failed") {
    Write-Host "✗ EXTRACTION FAILED" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error Output:" -ForegroundColor Red
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    $error = aws ssm get-command-invocation --command-id $CommandId --instance-id $InstanceId --region $Region --query "StandardErrorContent" --output text 2>$null
    Write-Host $error
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    Write-Host ""
    Write-Host "Standard Output:" -ForegroundColor Yellow
    $output = aws ssm get-command-invocation --command-id $CommandId --instance-id $InstanceId --region $Region --query "StandardOutputContent" --output text 2>$null
    Write-Host $output
    
} else {
    Write-Host "Status: $status" -ForegroundColor Yellow
}

Write-Host ""

