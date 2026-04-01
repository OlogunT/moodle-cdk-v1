#!/usr/bin/env pwsh
# Check status of cron installation on both instances

Param(
    [string]$Profile = 'tsin-account'
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "CHECKING CRON INSTALLATION STATUS" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Elearning
Write-Host "=== ELEARNING (i-011c65cd247389ee6) ===" -ForegroundColor Yellow
$eLearningCmd = "b9abcc36-ac01-4ad9-9b69-b4c719536262"
$eLearningStatus = aws ssm get-command-invocation --profile $Profile --command-id $eLearningCmd --instance-id i-011c65cd247389ee6 --query "Status" --output text 2>$null
Write-Host "Status: $eLearningStatus" -ForegroundColor $(if ($eLearningStatus -eq "Success") { "Green" } elseif ($eLearningStatus -eq "InProgress") { "Yellow" } else { "Red" })

if ($eLearningStatus -eq "Success") {
    Write-Host "Output (last 20 lines):" -ForegroundColor Cyan
    $output = aws ssm get-command-invocation --profile $Profile --command-id $eLearningCmd --instance-id i-011c65cd247389ee6 --query "StandardOutputContent" --output text
    $output -split "`n" | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
}

Write-Host ""

# Check if we can verify cron is running
Write-Host "=== Verifying Cron Service on Elearning ===" -ForegroundColor Yellow
$verifyCmdId = aws ssm send-command --profile $Profile --instance-ids i-011c65cd247389ee6 --document-name "AWS-RunShellScript" --parameters 'commands=["systemctl status crond --no-pager","crontab -u apache -l"]' --query "Command.CommandId" --output text
Start-Sleep -Seconds 5
$verifyOutput = aws ssm get-command-invocation --profile $Profile --command-id $verifyCmdId --instance-id i-011c65cd247389ee6 --query "StandardOutputContent" --output text 2>$null
Write-Host $verifyOutput

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "DONE" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

