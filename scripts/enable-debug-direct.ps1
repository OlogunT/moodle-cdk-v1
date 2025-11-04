# Enable Debug Mode on Training Moodle Site - Direct PHP Approach
# Uses PHP directly to edit the config file safely

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

# Create the PHP script content
$phpScript = @'
<?php
$config_file = '/app/moodle/config.php';

if (!file_exists($config_file)) {
    echo "ERROR: config.php not found\n";
    exit(1);
}

echo "=== Enabling Debug Mode ===\n";
echo "\n";

// Backup
echo "Step 1: Creating backup...\n";
$backup = $config_file . '.backup.' . time();
copy($config_file, $backup);
echo "Backup: $backup\n";
echo "\n";

// Read config
echo "Step 2: Reading config...\n";
$content = file_get_contents($config_file);

// Remove old debug settings
echo "Step 3: Removing old debug settings...\n";
$lines = explode("\n", $content);
$new_lines = array();
foreach ($lines as $line) {
    if (strpos($line, '$CFG->debug') === false &&
        strpos($line, '$CFG->debugdisplay') === false &&
        strpos($line, '$CFG->debugstringkeys') === false &&
        strpos($line, '$CFG->debugpageinfo') === false &&
        trim($line) !== '// Debug settings') {
        $new_lines[] = $line;
    }
}
$content = implode("\n", $new_lines);

// Add new debug settings
echo "Step 4: Adding new debug settings...\n";
$debug_code = "\n// Debug settings\n\$CFG->debug = (E_ALL | E_STRICT);\n\$CFG->debugdisplay = 1;\n\$CFG->debugstringkeys = true;\n\$CFG->debugpageinfo = true;\n";
$content = str_replace("require_once(__DIR__ . '/lib/setup.php');", $debug_code . "require_once(__DIR__ . '/lib/setup.php');", $content);

// Write config
echo "Step 5: Writing updated config...\n";
file_put_contents($config_file, $content);
echo "Config updated\n";
echo "\n";

// Verify
echo "Step 6: Verifying...\n";
$verify = file_get_contents($config_file);
if (strpos($verify, '$CFG->debug') !== false) {
    echo "Debug settings verified\n";
} else {
    echo "ERROR: Debug settings not found\n";
    exit(1);
}
echo "\n";

echo "SUCCESS: Debug mode enabled!\n";
echo "\n";
echo "Debug settings:\n";
echo "  - \$CFG->debug = (E_ALL | E_STRICT)\n";
echo "  - \$CFG->debugdisplay = 1\n";
echo "  - \$CFG->debugstringkeys = true\n";
echo "  - \$CFG->debugpageinfo = true\n";
?>
'@

# Create a temporary file
$tempPhpFile = [System.IO.Path]::GetTempFileName() + ".php"
$phpScript | Out-File -FilePath $tempPhpFile -Encoding UTF8

Write-Host "Step 2: Preparing PHP script..." -ForegroundColor Yellow
Write-Host "Script prepared" -ForegroundColor Green
Write-Host ""

# Create JSON parameters
Write-Host "Step 3: Preparing SSM command..." -ForegroundColor Yellow
$tempJsonFile = [System.IO.Path]::GetTempFileName()

# Read the PHP script
$phpContent = Get-Content -Path $tempPhpFile -Raw

# Create the commands array
$commands = @(
    "cat > /tmp/enable_debug.php << 'PHPEOF'",
    $phpContent,
    "PHPEOF",
    "sudo -u apache php /tmp/enable_debug.php",
    "cd /app/moodle && sudo -u apache php admin/cli/purge_caches.php 2>&1 | head -10"
)

# Create the JSON structure
$ssmParams = @{
    InstanceIds = @($instanceId)
    DocumentName = "AWS-RunShellScript"
    Parameters = @{
        commands = $commands
    }
} | ConvertTo-Json -Depth 10

$ssmParams | Out-File -FilePath $tempJsonFile -Encoding UTF8

Write-Host "Command prepared" -ForegroundColor Green
Write-Host ""

# Send the command via SSM
Write-Host "Step 4: Sending command to instance..." -ForegroundColor Yellow
$cmdOutput = aws ssm send-command `
    --cli-input-json file://$tempJsonFile `
    --region $REGION `
    --output json 2>&1

# Parse the JSON output
$cmdObj = $cmdOutput | ConvertFrom-Json
$commandId = $cmdObj.Command.CommandId

Write-Host "Command sent: $commandId" -ForegroundColor Green
Write-Host ""

# Clean up temp files
Remove-Item -Path $tempPhpFile -Force
Remove-Item -Path $tempJsonFile -Force

# Wait for command to complete
Write-Host "Step 5: Waiting for command to complete..." -ForegroundColor Yellow
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

