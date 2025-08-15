# Moodle Monitoring Script
# This script helps monitor the Moodle deployment and troubleshoot issues

param(
    [Parameter(Mandatory=$false)]
    [string]$Action = "status",
    
    [Parameter(Mandatory=$false)]
    [string]$LogGroup = "/aws/ec2/system",
    
    [Parameter(Mandatory=$false)]
    [int]$Minutes = 10
)

$Region = "ca-central-1"

Write-Host "Moodle Monitoring Script" -ForegroundColor Green
Write-Host "========================" -ForegroundColor Green

function Get-StackOutputs {
    try {
        $outputs = aws cloudformation describe-stacks --stack-name MoodleCdkStack --region $Region --query "Stacks[0].Outputs" --output json | ConvertFrom-Json
        return $outputs
    } catch {
        Write-Warning "Could not retrieve stack outputs. Stack may not be deployed yet."
        return $null
    }
}

function Get-AutoScalingGroupInstances {
    try {
        $asgName = aws autoscaling describe-auto-scaling-groups --region $Region --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName" --output text
        if ($asgName) {
            $instances = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --region $Region --query "AutoScalingGroups[0].Instances[*].InstanceId" --output text
            return $instances -split "`t"
        }
        return @()
    } catch {
        Write-Warning "Could not retrieve Auto Scaling Group instances"
        return @()
    }
}

function Test-MoodleHealth {
    param($Url)
    try {
        $response = Invoke-WebRequest -Uri "$Url/login/index.php" -Method GET -TimeoutSec 10 -UseBasicParsing
        if ($response.StatusCode -eq 200) {
            Write-Host "✓ Moodle is accessible and responding" -ForegroundColor Green
            return $true
        } else {
            Write-Host "✗ Moodle returned status code: $($response.StatusCode)" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "✗ Moodle is not accessible: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

switch ($Action.ToLower()) {
    "status" {
        Write-Host "Checking Moodle deployment status..." -ForegroundColor Yellow
        Write-Host ""
        
        # Get stack outputs
        $outputs = Get-StackOutputs
        if ($outputs) {
            Write-Host "Stack Outputs:" -ForegroundColor Green
            foreach ($output in $outputs) {
                Write-Host "  $($output.OutputKey): $($output.OutputValue)" -ForegroundColor White
            }
            Write-Host ""
            
            # Test Moodle health
            $moodleUrl = ($outputs | Where-Object { $_.OutputKey -eq "MoodleUrl" }).OutputValue
            if ($moodleUrl) {
                Write-Host "Testing Moodle accessibility..." -ForegroundColor Yellow
                Test-MoodleHealth -Url $moodleUrl
            }
        }
        
        # Check Auto Scaling Group instances
        Write-Host ""
        Write-Host "Auto Scaling Group Instances:" -ForegroundColor Green
        $instances = Get-AutoScalingGroupInstances
        if ($instances.Count -gt 0) {
            foreach ($instanceId in $instances) {
                if ($instanceId) {
                    $instanceInfo = aws ec2 describe-instances --instance-ids $instanceId --region $Region --query "Reservations[0].Instances[0].[State.Name,LaunchTime,PrivateIpAddress]" --output text
                    $state, $launchTime, $privateIp = $instanceInfo -split "`t"
                    Write-Host "  Instance: $instanceId" -ForegroundColor White
                    Write-Host "    State: $state" -ForegroundColor White
                    Write-Host "    Launch Time: $launchTime" -ForegroundColor White
                    Write-Host "    Private IP: $privateIp" -ForegroundColor White
                    Write-Host ""
                }
            }
        } else {
            Write-Host "  No instances found" -ForegroundColor Yellow
        }
        
        # Check RDS status
        Write-Host "RDS Database Status:" -ForegroundColor Green
        try {
            $dbInfo = aws rds describe-db-instances --region $Region --query "DBInstances[?contains(DBInstanceIdentifier, 'moodledatabase')].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Engine:Engine,EngineVersion:EngineVersion}" --output json | ConvertFrom-Json
            if ($dbInfo) {
                foreach ($db in $dbInfo) {
                    Write-Host "  Status: $($db.Status)" -ForegroundColor White
                    Write-Host "  Endpoint: $($db.Endpoint)" -ForegroundColor White
                    Write-Host "  Engine: $($db.Engine) $($db.EngineVersion)" -ForegroundColor White
                }
            } else {
                Write-Host "  No RDS instances found" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Could not retrieve RDS status" -ForegroundColor Yellow
        }
    }
    
    "logs" {
        Write-Host "Tailing CloudWatch logs for $LogGroup..." -ForegroundColor Yellow
        Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow
        Write-Host ""
        
        aws logs tail $LogGroup --follow --region $Region
    }
    
    "recent-logs" {
        Write-Host "Showing recent logs from $LogGroup (last $Minutes minutes)..." -ForegroundColor Yellow
        Write-Host ""
        
        $startTime = (Get-Date).AddMinutes(-$Minutes).ToString("yyyy-MM-ddTHH:mm:ssZ")
        aws logs filter-log-events --log-group-name $LogGroup --start-time $startTime --region $Region --query "events[*].[timestamp,message]" --output table
    }
    
    "health" {
        $outputs = Get-StackOutputs
        if ($outputs) {
            $moodleUrl = ($outputs | Where-Object { $_.OutputKey -eq "MoodleUrl" }).OutputValue
            if ($moodleUrl) {
                Write-Host "Testing Moodle health at $moodleUrl..." -ForegroundColor Yellow
                $isHealthy = Test-MoodleHealth -Url $moodleUrl
                
                if ($isHealthy) {
                    Write-Host ""
                    Write-Host "Moodle is ready! Access it at: $moodleUrl" -ForegroundColor Green
                    Write-Host "Default credentials:" -ForegroundColor Yellow
                    Write-Host "  Username: moodle-admin" -ForegroundColor White
                    Write-Host "  Password: TempPass123!" -ForegroundColor White
                    Write-Host ""
                    Write-Host "Please change the password after first login!" -ForegroundColor Red
                } else {
                    Write-Host ""
                    Write-Host "Moodle is not ready yet. Check the logs for more information:" -ForegroundColor Yellow
                    Write-Host "  .\monitor.ps1 -Action logs" -ForegroundColor White
                }
            }
        }
    }
    
    "troubleshoot" {
        Write-Host "Running troubleshooting checks..." -ForegroundColor Yellow
        Write-Host ""
        
        # Check if stack exists
        Write-Host "1. Checking if CloudFormation stack exists..." -ForegroundColor Yellow
        try {
            $stackStatus = aws cloudformation describe-stacks --stack-name MoodleCdkStack --region $Region --query "Stacks[0].StackStatus" --output text
            Write-Host "   Stack Status: $stackStatus" -ForegroundColor Green
        } catch {
            Write-Host "   ✗ Stack not found or error occurred" -ForegroundColor Red
            return
        }
        
        # Check Auto Scaling Group
        Write-Host ""
        Write-Host "2. Checking Auto Scaling Group..." -ForegroundColor Yellow
        $instances = Get-AutoScalingGroupInstances
        if ($instances.Count -eq 0) {
            Write-Host "   ✗ No instances in Auto Scaling Group" -ForegroundColor Red
        } else {
            Write-Host "   ✓ Found $($instances.Count) instance(s)" -ForegroundColor Green
        }
        
        # Check recent errors in logs
        Write-Host ""
        Write-Host "3. Checking for recent errors in logs..." -ForegroundColor Yellow
        try {
            $startTime = (Get-Date).AddMinutes(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $errors = aws logs filter-log-events --log-group-name "/aws/ec2/system" --start-time $startTime --region $Region --filter-pattern "ERROR" --query "events[*].message" --output text
            if ($errors) {
                Write-Host "   ⚠ Found recent errors:" -ForegroundColor Yellow
                Write-Host $errors -ForegroundColor Red
            } else {
                Write-Host "   ✓ No recent errors found" -ForegroundColor Green
            }
        } catch {
            Write-Host "   ⚠ Could not check logs" -ForegroundColor Yellow
        }
        
        # Test ALB health
        Write-Host ""
        Write-Host "4. Testing Application Load Balancer..." -ForegroundColor Yellow
        $outputs = Get-StackOutputs
        if ($outputs) {
            $moodleUrl = ($outputs | Where-Object { $_.OutputKey -eq "MoodleUrl" }).OutputValue
            if ($moodleUrl) {
                Test-MoodleHealth -Url $moodleUrl | Out-Null
            }
        }
    }
    
    default {
        Write-Host "Usage: .\monitor.ps1 [-Action <status|logs|recent-logs|health|troubleshoot>] [-LogGroup <log-group-name>] [-Minutes <number>]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  status       - Show overall deployment status (default)"
        Write-Host "  logs         - Tail CloudWatch logs in real-time"
        Write-Host "  recent-logs  - Show recent log entries"
        Write-Host "  health       - Test Moodle accessibility"
        Write-Host "  troubleshoot - Run troubleshooting checks"
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  -LogGroup    - CloudWatch log group to monitor (default: /aws/ec2/system)"
        Write-Host "  -Minutes     - Number of minutes for recent logs (default: 10)"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host "  .\monitor.ps1                                    # Show status"
        Write-Host "  .\monitor.ps1 -Action logs                       # Tail system logs"
        Write-Host "  .\monitor.ps1 -Action logs -LogGroup /aws/ec2/moodle  # Tail Moodle logs"
        Write-Host "  .\monitor.ps1 -Action recent-logs -Minutes 30    # Show last 30 minutes"
    }
}
