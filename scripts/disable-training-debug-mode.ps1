# Disable Debug Mode on Training Moodle Site
# This script removes debug settings from the Moodle config.php file

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Disabling Debug Mode on Training Moodle Site                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Configuration
$REGION = "ca-central-1"
$INSTANCE_TAG = "Training"
$CONFIG_FILE = "/app/moodle/config.php"

# Get the training instance ID
Write-Host "Step 1: Finding Training Moodle instance..." -ForegroundColor Yellow
$instanceId = aws ec2 describe-instances `
    --region $REGION `
    --filters "Name=tag:Instance,Values=$INSTANCE_TAG" "Name=instance-state-name,Values=running" `
    --query 'Reservations[0].Instances[0].InstanceId' `
    --output text

if (-not $instanceId -or $instanceId -eq "None") {
    Write-Host "✗ No running Training Moodle instance found" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Found instance: $instanceId" -ForegroundColor Green
Write-Host ""

# Create the disable debug script
$disableScript = @"
#!/bin/bash
set -e

echo "=== Disabling Debug Mode on Training Moodle ==="
echo ""

CONFIG_FILE="$CONFIG_FILE"

if [ ! -f "\$CONFIG_FILE" ]; then
    echo "✗ config.php not found at \$CONFIG_FILE"
    exit 1
fi

echo "Step 1: Backing up config.php..."
cp "\$CONFIG_FILE" "\$CONFIG_FILE.backup.$(date +%s)"
echo "✓ Backup created"
echo ""

echo "Step 2: Removing debug settings from config.php..."

# Remove debug settings
sed -i '/\$CFG->debug/d' "\$CONFIG_FILE"
sed -i '/\$CFG->debugdisplay/d' "\$CONFIG_FILE"
sed -i '/\$CFG->debugstringkeys/d' "\$CONFIG_FILE"
sed -i '/\$CFG->debugpageinfo/d' "\$CONFIG_FILE"
sed -i '/^\/\/ Debug settings$/d' "\$CONFIG_FILE"

echo "✓ Debug settings removed"
echo ""

echo "Step 3: Purging Moodle caches..."
cd /app/moodle
sudo -u apache php admin/cli/purge_caches.php 2>&1 | head -10
echo ""

echo "✓ Debug mode disabled successfully!"
echo ""
echo "Debug settings have been removed from config.php"
echo "Backup saved to: \$CONFIG_FILE.backup.*"
"@

Write-Host "Step 2: Sending disable debug script to instance..." -ForegroundColor Yellow

# Send the command via SSM
$cmd = aws ssm send-command `
    --instance-ids $instanceId `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=$($disableScript | ConvertTo-Json -AsArray)" `
    --region $REGION `
    --output json | ConvertFrom-Json

$commandId = $cmd.Command.CommandId
Write-Host "✓ Command sent: $commandId" -ForegroundColor Green
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
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
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

if ($errorOutput) {
    Write-Host "Errors/Warnings:" -ForegroundColor Yellow
    Write-Host $errorOutput
    Write-Host ""
}

Write-Host "✓ Debug mode has been disabled!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Access the training Moodle site at https://training.tsin.ca" -ForegroundColor Cyan
Write-Host "2. Debug information will no longer be displayed" -ForegroundColor Cyan
Write-Host "3. To enable debug mode again, run: scripts/enable-training-debug-mode.ps1" -ForegroundColor Cyan

