#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Fixes Moodle ERR_TOO_MANY_REDIRECTS / redirect loop issues

.DESCRIPTION
    This script fixes the common redirect loop issue that occurs when Moodle is behind
    an Application Load Balancer (ALB) with SSL termination. The issue is caused by
    incorrect reverse proxy settings in Moodle's config.php.

    Root Cause:
    - When $CFG->reverseproxy = true, Moodle blocks direct access
    - When $CFG->reverseproxy = false but $CFG->sslproxy is missing, Moodle redirects
      HTTP to HTTPS infinitely because it doesn't recognize the ALB's SSL termination

    Solution:
    - Set $CFG->sslproxy = true (tells Moodle to trust X-Forwarded-Proto header)
    - Remove or set $CFG->reverseproxy = false (allows direct access from ALB)
    - Ensure $CFG->wwwroot uses https://

.PARAMETER Region
    AWS region where the Moodle infrastructure is deployed (default: ca-central-1)

.PARAMETER StackName
    CloudFormation stack name (default: MoodleCdkStack)

.PARAMETER CustomDomain
    Custom domain for Moodle (default: https://elearning.tsin.ca)

.PARAMETER InstanceIds
    Specific instance IDs to fix. If not provided, fixes all healthy instances in the ASG

.PARAMETER VerifyAfter
    Run verification tests after applying the fix (default: true)

.EXAMPLE
    ./scripts/fix-redirect-loop.ps1
    Fixes all instances with default settings

.EXAMPLE
    ./scripts/fix-redirect-loop.ps1 -InstanceIds i-1234567890abcdef0
    Fixes a specific instance

.EXAMPLE
    ./scripts/fix-redirect-loop.ps1 -CustomDomain "https://moodle.example.com"
    Fixes with a custom domain

.NOTES
    Author: Moodle CDK Team
    Date: 2025-10-18
    Version: 1.0
#>

param(
    [string]$Region = "ca-central-1",
    [string]$StackName = "MoodleCdkStack",
    [string]$CustomDomain = "https://elearning.tsin.ca",
    [string[]]$InstanceIds,
    [switch]$VerifyAfter = $true
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# Color output functions
function Write-Success { param([string]$Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "ℹ $Message" -ForegroundColor Cyan }
function Write-Warning { param([string]$Message) Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Error { param([string]$Message) Write-Host "✗ $Message" -ForegroundColor Red }

Write-Host "`n╔════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   MOODLE REDIRECT LOOP FIX                     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Info "Region: $Region"
Write-Info "Stack: $StackName"
Write-Info "Domain: $CustomDomain"
Write-Host ""

# Function to get instances
function Get-MoodleInstances {
    param([string]$Region, [string]$StackName, [string[]]$SpecificIds)
    
    if ($SpecificIds) {
        Write-Info "Using specified instance IDs: $($SpecificIds -join ', ')"
        return $SpecificIds
    }
    
    Write-Info "Finding healthy instances in Auto Scaling Group..."
    $asgName = aws autoscaling describe-auto-scaling-groups --region $Region `
        --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName | [0]" `
        --output text 2>$null
    
    if (-not $asgName -or $asgName -eq 'None') {
        throw "Could not find Moodle Auto Scaling Group in stack $StackName"
    }
    
    Write-Info "Found ASG: $asgName"
    
    $instancesText = aws autoscaling describe-auto-scaling-groups --region $Region `
        --auto-scaling-group-names $asgName `
        --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy' && LifecycleState=='InService'].InstanceId" `
        --output text 2>$null
    
    if (-not $instancesText) {
        throw "No healthy instances found in ASG $asgName"
    }
    
    $instances = $instancesText -split "`t" | Where-Object { $_ }
    Write-Success "Found $($instances.Count) healthy instance(s)"
    return $instances
}

# Function to create the fix script
function Get-FixScript {
    param([string]$Domain)
    
    return @{
        commands = @(
            "set -euo pipefail",
            "echo '=== MOODLE REDIRECT LOOP FIX ==='",
            "echo 'Fixing reverse proxy configuration for ALB with SSL termination'",
            "echo ''",
            "CFG=/app/moodle/config.php",
            "if [ ! -f `"`$CFG`" ]; then",
            "  echo 'ERROR: Config file not found at /app/moodle/config.php'",
            "  exit 1",
            "fi",
            "echo 'Creating backup...'",
            "cp `"`$CFG`" `"`${CFG}.backup.redirect-fix.`$(date +%Y%m%d_%H%M%S)`"",
            "echo ''",
            "echo '--- BEFORE ---'",
            "grep -n -E '(wwwroot|reverseproxy|sslproxy)' `"`$CFG`" || echo 'No proxy settings found'",
            "echo ''",
            "echo 'Removing problematic proxy settings...'",
            "sed -i '/^\`$CFG->reverseproxy/d' `"`$CFG`"",
            "sed -i '/^\`$CFG->sslproxy/d' `"`$CFG`"",
            "sed -i '/^\`$CFG->getremoteaddrconf/d' `"`$CFG`"",
            "sed -i '/^\`$CFG->cookiesecure/d' `"`$CFG`"",
            "sed -i '/^\`$CFG->loginhttps/d' `"`$CFG`"",
            "echo ''",
            "echo 'Adding correct SSL proxy setting...'",
            "sed -i '/require_once.*lib\\/setup\\.php/i \`$CFG->sslproxy = true;' `"`$CFG`"",
            "echo ''",
            "echo 'Ensuring wwwroot uses HTTPS...'",
            "if grep -q '^\`$CFG->wwwroot' `"`$CFG`"; then",
            "  sed -i `"s|^\`$CFG->wwwroot.*|\`$CFG->wwwroot = '$Domain';|`" `"`$CFG`"",
            "else",
            "  sed -i '/require_once.*lib\\/setup\\.php/i \`$CFG->wwwroot = '\''$Domain'\'';' `"`$CFG`"",
            "fi",
            "echo ''",
            "echo '--- AFTER ---'",
            "grep -n -E '(wwwroot|sslproxy|require_once)' `"`$CFG`" | head -15",
            "echo ''",
            "echo 'Validating PHP syntax...'",
            "php -l `"`$CFG`"",
            "echo ''",
            "echo 'Clearing Moodle caches...'",
            "rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/* 2>/dev/null || true",
            "sudo -u apache php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || echo 'CLI cache purge skipped'",
            "echo ''",
            "echo 'Restarting services...'",
            "systemctl restart php-fpm httpd",
            "sleep 3",
            "echo ''",
            "echo 'Testing local access...'",
            "curl -sI http://localhost/ | head -5",
            "echo ''",
            "echo '=== FIX COMPLETE ==='",
            "echo 'Configuration applied:'",
            "echo '  - sslproxy: true (handles ALB SSL termination)'",
            "echo '  - reverseproxy: removed (allows direct access from ALB)'",
            "echo '  - wwwroot: $Domain'",
            "echo ''",
            "echo 'The redirect loop should now be resolved.'"
        )
    }
}

# Function to apply fix to instances
function Invoke-FixOnInstances {
    param([string]$Region, [string[]]$Instances, [hashtable]$FixScript)
    
    Write-Info "Applying fix to $($Instances.Count) instance(s)..."
    Write-Host ""
    
    $tmpFile = New-TemporaryFile
    try {
        $json = $FixScript | ConvertTo-Json -Compress -Depth 10
        [System.IO.File]::WriteAllText($tmpFile.FullName, $json, [System.Text.UTF8Encoding]::new($false))
        
        foreach ($instanceId in $Instances) {
            Write-Host "─────────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Info "Processing instance: $instanceId"
            
            $cmdId = aws ssm send-command --region $Region `
                --instance-ids $instanceId `
                --document-name "AWS-RunShellScript" `
                --parameters "file://$($tmpFile.FullName)" `
                --query "Command.CommandId" `
                --output text 2>&1
            
            if (-not $cmdId -or $cmdId -match "error") {
                Write-Error "Failed to send command to $instanceId"
                continue
            }
            
            Write-Info "Command ID: $cmdId"
            Write-Info "Waiting for command to complete..."
            Start-Sleep -Seconds 15
            
            $status = aws ssm get-command-invocation --region $Region `
                --command-id $cmdId --instance-id $instanceId `
                --query "Status" --output text 2>&1
            
            $output = aws ssm get-command-invocation --region $Region `
                --command-id $cmdId --instance-id $instanceId `
                --query "StandardOutputContent" --output text 2>&1
            
            Write-Host "`nStatus: $status" -ForegroundColor $(if($status -eq 'Success'){'Green'}else{'Yellow'})
            Write-Host "`nOutput:" -ForegroundColor White
            Write-Host $output
            
            if ($status -eq 'Success') {
                Write-Success "Instance $instanceId fixed successfully"
            } else {
                Write-Warning "Instance $instanceId status: $status"
            }
            Write-Host ""
        }
    }
    finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
}

# Function to verify the fix
function Test-MoodleSite {
    param([string]$Domain)
    
    Write-Host "`n╔════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   VERIFICATION TESTS                           ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════╝`n" -ForegroundColor Green
    
    Write-Info "Testing: $Domain"
    Write-Host ""
    
    # Test 1: Health endpoint
    Write-Host "1. Health Endpoint Test..." -ForegroundColor Cyan
    $health = curl -s -o $null -w "%{http_code}" "$Domain/health" 2>&1
    if ($health -eq "200" -or $health -eq "OK") {
        Write-Success "Health endpoint responding"
    } else {
        Write-Warning "Health endpoint returned: $health"
    }
    
    # Test 2: Homepage
    Write-Host "`n2. Homepage Test..." -ForegroundColor Cyan
    $homepage = curl -sL --max-time 15 "$Domain/" 2>&1
    if ($homepage -match "Log in|login") {
        Write-Success "Login page loads successfully"
    } else {
        Write-Warning "Login page may not be loading correctly"
    }
    
    # Test 3: Moodle detection
    Write-Host "`n3. Moodle Detection..." -ForegroundColor Cyan
    if ($homepage -match "Moodle|moodle") {
        Write-Success "Moodle detected"
    } else {
        Write-Warning "Moodle not detected in page content"
    }
    
    # Test 4: Error check
    Write-Host "`n4. Error Page Check..." -ForegroundColor Cyan
    if ($homepage -match "alert-danger|Reverse proxy enabled|ERR_TOO_MANY_REDIRECTS") {
        Write-Error "Error page or redirect loop still detected!"
    } else {
        Write-Success "No error pages detected"
    }
    
    # Test 5: Redirect count
    Write-Host "`n5. Redirect Loop Test..." -ForegroundColor Cyan
    $redirectInfo = curl -sL --max-time 10 --max-redirs 20 -w "REDIRECTS:%{num_redirects}" -o $null "$Domain/" 2>&1
    if ($redirectInfo -match "REDIRECTS:(\d+)") {
        $redirectCount = [int]$Matches[1]
        if ($redirectCount -ge 10) {
            Write-Error "Redirect loop detected! ($redirectCount redirects)"
        } elseif ($redirectCount -le 3) {
            Write-Success "Normal redirect behavior ($redirectCount redirects)"
        } else {
            Write-Warning "Multiple redirects detected ($redirectCount redirects)"
        }
    }
    
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Success "Verification complete!"
    Write-Host "Site URL: $Domain" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Green
}

# Main execution
try {
    # Get instances to fix
    $instances = Get-MoodleInstances -Region $Region -StackName $StackName -SpecificIds $InstanceIds
    
    # Create fix script
    $fixScript = Get-FixScript -Domain $CustomDomain
    
    # Apply fix
    Invoke-FixOnInstances -Region $Region -Instances $instances -FixScript $fixScript
    
    # Verify if requested
    if ($VerifyAfter) {
        Start-Sleep -Seconds 5
        Test-MoodleSite -Domain $CustomDomain
    }
    
    Write-Success "All operations completed successfully!"
    Write-Host ""
}
catch {
    Write-Error "An error occurred: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

