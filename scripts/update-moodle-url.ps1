# Post-deployment script to update Moodle configuration with correct ALB URL
# This script should be run after the CDK deployment is complete

param(
    [Parameter(Mandatory=$false)]
    [string]$StackName = "MoodleCdkStack",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "ca-central-1"
)

Write-Host "Moodle URL Update Script" -ForegroundColor Green
Write-Host "========================" -ForegroundColor Green

# Get the ALB URL from CloudFormation outputs
Write-Host "Retrieving ALB URL from CloudFormation..." -ForegroundColor Yellow
try {
    $outputs = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs" --output json | ConvertFrom-Json
    $albUrl = ($outputs | Where-Object { $_.OutputKey -eq "MoodleUrl" }).OutputValue
    
    if (-not $albUrl) {
        Write-Error "Could not find MoodleUrl in CloudFormation outputs"
        exit 1
    }
    
    Write-Host "Found ALB URL: $albUrl" -ForegroundColor Green
} catch {
    Write-Error "Failed to retrieve CloudFormation outputs: $($_.Exception.Message)"
    exit 1
}

# Get Auto Scaling Group instances
Write-Host "Finding Moodle instances..." -ForegroundColor Yellow
try {
    $asgName = aws autoscaling describe-auto-scaling-groups --region $Region --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName" --output text
    
    if (-not $asgName) {
        Write-Error "Could not find Moodle Auto Scaling Group"
        exit 1
    }
    
    $instances = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --query "AutoScalingGroups[0].Instances[*].InstanceId" --output text
    $instanceList = $instances -split "`t"
    
    Write-Host "Found $($instanceList.Count) instance(s): $($instanceList -join ', ')" -ForegroundColor Green
} catch {
    Write-Error "Failed to retrieve Auto Scaling Group instances: $($_.Exception.Message)"
    exit 1
}

# Update Moodle configuration on each instance
foreach ($instanceId in $instanceList) {
    if ($instanceId) {
        Write-Host ""
        Write-Host "Updating Moodle configuration on instance: $instanceId" -ForegroundColor Yellow
        
        # Create the update script
        $updateScript = @"
#!/bin/bash
set -e

echo "Updating Moodle configuration with ALB URL: $albUrl"

# Check if Moodle is installed
if [ ! -f "/app/moodle/config.php" ]; then
    echo "Moodle config.php not found. Installation may not be complete."
    exit 1
fi

# Backup current config
cp /app/moodle/config.php /app/moodle/config.php.backup.`$(date +%Y%m%d_%H%M%S)

# Update the wwwroot in config.php
sed -i "s|^\$CFG->wwwroot.*|\$CFG->wwwroot = '$albUrl';|" /app/moodle/config.php

# Verify the change
if grep -q "$albUrl" /app/moodle/config.php; then
    echo "Successfully updated Moodle wwwroot to: $albUrl"
    
    # Clear Moodle cache
    if [ -d "/data/moodledata/cache" ]; then
        rm -rf /data/moodledata/cache/*
        echo "Cleared Moodle cache"
    fi
    
    # Restart Apache to ensure changes take effect
    systemctl restart httpd
    echo "Restarted Apache"
    
    echo "Moodle configuration update completed successfully!"
else
    echo "Failed to update Moodle configuration"
    exit 1
fi
"@

        # Write the script to a temporary file
        $tempScript = "/tmp/update-moodle-url-$instanceId.sh"
        $updateScript | Out-File -FilePath $tempScript -Encoding UTF8
        
        try {
            # Execute the script on the instance using SSM
            Write-Host "Executing update script via SSM..." -ForegroundColor Yellow
            
            $commandId = aws ssm send-command `
                --instance-ids $instanceId `
                --document-name "AWS-RunShellScript" `
                --parameters "commands=`"$updateScript`"" `
                --region $Region `
                --query "Command.CommandId" `
                --output text
            
            if ($commandId) {
                Write-Host "Command sent with ID: $commandId" -ForegroundColor Green
                
                # Wait for command to complete
                Write-Host "Waiting for command to complete..." -ForegroundColor Yellow
                $timeout = 300 # 5 minutes
                $elapsed = 0
                $interval = 10
                
                do {
                    Start-Sleep -Seconds $interval
                    $elapsed += $interval
                    
                    $status = aws ssm get-command-invocation `
                        --command-id $commandId `
                        --instance-id $instanceId `
                        --region $Region `
                        --query "Status" `
                        --output text 2>$null
                    
                    if ($status -eq "Success") {
                        Write-Host "✓ Command completed successfully on $instanceId" -ForegroundColor Green
                        
                        # Get command output
                        $output = aws ssm get-command-invocation `
                            --command-id $commandId `
                            --instance-id $instanceId `
                            --region $Region `
                            --query "StandardOutputContent" `
                            --output text
                        
                        Write-Host "Command output:" -ForegroundColor Cyan
                        Write-Host $output -ForegroundColor White
                        break
                    } elseif ($status -eq "Failed") {
                        Write-Host "✗ Command failed on $instanceId" -ForegroundColor Red
                        
                        # Get error output
                        $errorOutput = aws ssm get-command-invocation `
                            --command-id $commandId `
                            --instance-id $instanceId `
                            --region $Region `
                            --query "StandardErrorContent" `
                            --output text
                        
                        Write-Host "Error output:" -ForegroundColor Red
                        Write-Host $errorOutput -ForegroundColor White
                        break
                    } elseif ($elapsed -ge $timeout) {
                        Write-Host "⚠ Command timed out on $instanceId" -ForegroundColor Yellow
                        break
                    } else {
                        Write-Host "Command status: $status (elapsed: ${elapsed}s)" -ForegroundColor Yellow
                    }
                } while ($true)
            } else {
                Write-Host "✗ Failed to send command to $instanceId" -ForegroundColor Red
            }
        } catch {
            Write-Host "✗ Error updating instance $instanceId`: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        # Clean up temp file
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force
        }
    }
}

Write-Host ""
Write-Host "Moodle URL update process completed!" -ForegroundColor Green
Write-Host "You can now access Moodle at: $albUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "To verify the update worked:" -ForegroundColor Yellow
Write-Host "1. Wait a few minutes for the changes to take effect"
Write-Host "2. Access Moodle at the ALB URL"
Write-Host "3. Check that all links and redirects work correctly"
