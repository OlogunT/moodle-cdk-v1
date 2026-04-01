# Enable Debug Mode on Training Moodle Site
# This script adds debug settings to the Moodle config.php file

Write-Host "Enabling Debug Mode on Training Moodle Site" -ForegroundColor Cyan
Write-Host ""

# Configuration
$REGION = "ca-central-1"
$INSTANCE_TAG = "Training"

# Get the training instance ID
Write-Host "Step 1: Finding Training Moodle instance..." -ForegroundColor Yellow
$instanceId = aws ec2 describe-instances `
    --region $REGION `
    --filters "Name=tag:Instance,Values=$INSTANCE_TAG" "Name=instance-state-name,Values=running" `
    --query 'Reservations[0].Instances[0].InstanceId' `
    --output text

if (-not $instanceId -or $instanceId -eq "None") {
    Write-Host "No running Training Moodle instance found" -ForegroundColor Red
    exit 1
}

Write-Host "Found instance: $instanceId" -ForegroundColor Green
Write-Host ""

# Send the command via SSM
Write-Host "Step 2: Sending debug configuration commands to instance..." -ForegroundColor Yellow

# Create a simple command to add debug settings using sed
$debugCommand = @"
#!/bin/bash
set -e

CONFIG_FILE="/app/moodle/config.php"

# Backup
cp `$CONFIG_FILE `$CONFIG_FILE.backup.\$(date +%s)

# Remove old debug settings if they exist
sed -i '/\$CFG->debug/d' `$CONFIG_FILE
sed -i '/\$CFG->debugdisplay/d' `$CONFIG_FILE
sed -i '/\$CFG->debugstringkeys/d' `$CONFIG_FILE
sed -i '/\$CFG->debugpageinfo/d' `$CONFIG_FILE
sed -i '/^\/\/ Debug settings$/d' `$CONFIG_FILE

# Add new debug settings before require_once
sed -i '/require_once.*lib\/setup\.php/i \\
// Debug settings\\
\$CFG->debug = (E_ALL | E_STRICT);\\
\$CFG->debugdisplay = 1;\\
\$CFG->debugstringkeys = true;\\
\$CFG->debugpageinfo = true;' `$CONFIG_FILE

# Purge caches
cd /app/moodle
sudo -u apache php admin/cli/purge_caches.php

echo "Debug mode enabled successfully!"
"@

# Write to temp file and execute
$tempFile = [System.IO.Path]::GetTempFileName()
$debugCommand | Out-File -FilePath $tempFile -Encoding ASCII -NoNewline

# Read the file content
$scriptContent = Get-Content -Path $tempFile -Raw

# Send via SSM - use a simpler format
$cmdOutput = aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters commands="$scriptContent" `
    --region $REGION `
    --output json 2>&1

# Clean up temp file
Remove-Item -Path $tempFile -Force

# Parse the JSON output
$cmdObj = $cmdOutput | ConvertFrom-Json
$commandId = $cmdObj.Command.CommandId

Write-Host "Command sent: $commandId" -ForegroundColor Green
Write-Host ""

# Wait for command to complete
Write-Host "Step 3: Waiting for command to complete..." -ForegroundColor Yellow
$maxAttempts = 30
$attempt = 0

while ($attempt -lt $maxAttempts) {
    Start-Sleep -Seconds 2
    $status = aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $instanceId `
        --region $REGION `
        --query 'Status' `
        --output text

    if ($status -eq "Success" -or $status -eq "Failed") {
        break
    }
    $attempt++
}

# Get the output
$output = aws ssm get-command-invocation `
    --command-id $commandId `
    --instance-id $instanceId `
    --region $REGION `
    --query 'StandardOutputContent' `
    --output text

Write-Host ""
Write-Host "Command Output:" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host $output
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check for errors
$errorOutput = aws ssm get-command-invocation `
    --command-id $commandId `
    --instance-id $instanceId `
    --region $REGION `
    --query 'StandardErrorContent' `
    --output text

if ($errorOutput -and $errorOutput -ne "") {
    Write-Host "Errors/Warnings:" -ForegroundColor Yellow
    Write-Host $errorOutput
    Write-Host ""
}

Write-Host "Debug mode configuration complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Access the training Moodle site at https://training.tsin.ca" -ForegroundColor Cyan
Write-Host "2. Debug information will now be displayed on pages" -ForegroundColor Cyan
Write-Host "3. Check /var/log/httpd/error_log for detailed error messages" -ForegroundColor Cyan
Write-Host "4. To disable debug mode, run: scripts/disable-training-debug-mode.ps1" -ForegroundColor Cyan

