# Enable Debug Mode on Training Moodle Site - Simple Version
# Uses JSON file for parameters to avoid PowerShell interpretation issues

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

# Update the JSON file with the correct instance ID
Write-Host "Step 2: Preparing parameters..." -ForegroundColor Yellow
$paramsFile = "scripts/enable-debug-params.json"
$params = Get-Content -Path $paramsFile | ConvertFrom-Json
$params.InstanceIds = @($instanceId)
$params | ConvertTo-Json -Depth 10 | Out-File -FilePath $paramsFile -Encoding UTF8

Write-Host "Parameters updated" -ForegroundColor Green
Write-Host ""

# Send the command via SSM using the JSON file
Write-Host "Step 3: Sending debug configuration to instance..." -ForegroundColor Yellow
$cmdOutput = aws ssm send-command `
    --cli-input-json file://$paramsFile `
    --region $REGION `
    --output json 2>&1

# Parse the JSON output
$cmdObj = $cmdOutput | ConvertFrom-Json
$commandId = $cmdObj.Command.CommandId

Write-Host "Command sent: $commandId" -ForegroundColor Green
Write-Host ""

# Wait for command to complete
Write-Host "Step 4: Waiting for command to complete..." -ForegroundColor Yellow
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

