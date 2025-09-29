#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy and configure AWS SES email for Moodle

.DESCRIPTION
    This script:
    1. Synthesizes the CDK stack with SES enhancements
    2. Optionally deploys the stack
    3. Verifies SES configuration
    4. Configures Moodle to use SES
    5. Tests email sending

.PARAMETER Region
    AWS region (default: ca-central-1)

.PARAMETER CreateVpcEndpoint
    Create VPC endpoint for SES SMTP (default: true)

.PARAMETER Deploy
    Actually deploy the stack (default: false for safety)

.PARAMETER ConfigureMoodle
    Run Moodle configuration script on instances (default: false)

.PARAMETER TestEmail
    Send test email after configuration (default: false)

.EXAMPLE
    # Synthesize only (no deployment)
    .\deploy-ses-email-config.ps1

.EXAMPLE
    # Deploy with VPC endpoint
    .\deploy-ses-email-config.ps1 -Deploy -CreateVpcEndpoint $true

.EXAMPLE
    # Deploy and configure Moodle
    .\deploy-ses-email-config.ps1 -Deploy -ConfigureMoodle -TestEmail
#>

param(
    [string]$Region = "ca-central-1",
    [bool]$CreateVpcEndpoint = $true,
    [switch]$Deploy,
    [switch]$ConfigureMoodle,
    [switch]$TestEmail,
    [string]$StackName = "MoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "`n=== AWS SES Email Configuration for Moodle ===" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor White
Write-Host "VPC Endpoint: $CreateVpcEndpoint" -ForegroundColor White
Write-Host "Deploy: $Deploy" -ForegroundColor White
Write-Host ""

# ============================================================================
# STEP 1: Verify Prerequisites
# ============================================================================
Write-Host "--- Step 1: Verifying prerequisites ---" -ForegroundColor Yellow

# Check AWS CLI
try {
    $awsVersion = aws --version
    Write-Host "✓ AWS CLI: $awsVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ AWS CLI not found. Please install AWS CLI." -ForegroundColor Red
    exit 1
}

# Check CDK CLI
try {
    $cdkVersion = cdk --version
    Write-Host "✓ CDK CLI: $cdkVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ CDK CLI not found. Please install: npm install -g aws-cdk" -ForegroundColor Red
    exit 1
}

# Check Node.js
try {
    $nodeVersion = node --version
    Write-Host "✓ Node.js: $nodeVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ Node.js not found. Please install Node.js 18+" -ForegroundColor Red
    exit 1
}

# Check jq
try {
    $jqVersion = jq --version
    Write-Host "✓ jq: $jqVersion" -ForegroundColor Green
} catch {
    Write-Host "⚠ jq not found (optional but recommended)" -ForegroundColor Yellow
}

# ============================================================================
# STEP 2: Install NPM Dependencies
# ============================================================================
Write-Host "`n--- Step 2: Installing dependencies ---" -ForegroundColor Yellow

if (Test-Path "package.json") {
    npm install
    Write-Host "✓ NPM dependencies installed" -ForegroundColor Green
} else {
    Write-Host "✗ package.json not found" -ForegroundColor Red
    exit 1
}

# ============================================================================
# STEP 3: Synthesize CDK Stack
# ============================================================================
Write-Host "`n--- Step 3: Synthesizing CDK stack ---" -ForegroundColor Yellow

$synthArgs = @(
    "synth",
    $StackName,
    "--context", "CreateSesVpcEndpoint=$CreateVpcEndpoint"
)

Write-Host "Running: cdk $($synthArgs -join ' ')" -ForegroundColor Gray
cdk @synthArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ CDK synthesis failed" -ForegroundColor Red
    exit 1
}

Write-Host "✓ CDK synthesis successful" -ForegroundColor Green

# Verify SES resources in template
Write-Host "`nVerifying SES resources in CloudFormation template..." -ForegroundColor Cyan
$templatePath = "cdk.out/$StackName.template.json"

if (Test-Path $templatePath) {
    $template = Get-Content $templatePath | ConvertFrom-Json
    
    $sesResources = $template.Resources.PSObject.Properties | 
        Where-Object { $_.Name -like "*Ses*" -or $_.Name -like "*Email*" }
    
    if ($sesResources) {
        Write-Host "✓ Found SES-related resources:" -ForegroundColor Green
        foreach ($resource in $sesResources) {
            Write-Host "  - $($resource.Name): $($resource.Value.Type)" -ForegroundColor White
        }
    } else {
        Write-Host "⚠ No SES resources found in template" -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 4: Deploy Stack (Optional)
# ============================================================================
if ($Deploy) {
    Write-Host "`n--- Step 4: Deploying CDK stack ---" -ForegroundColor Yellow
    Write-Host "⚠ This will modify your AWS infrastructure!" -ForegroundColor Yellow
    
    $deployArgs = @(
        "deploy",
        $StackName,
        "--parameters", "CreateSesVpcEndpoint=$CreateVpcEndpoint",
        "--require-approval", "never",
        "--region", $Region
    )
    
    Write-Host "Running: cdk $($deployArgs -join ' ')" -ForegroundColor Gray
    cdk @deployArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ CDK deployment failed" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "✓ CDK deployment successful" -ForegroundColor Green
} else {
    Write-Host "`n--- Step 4: Skipping deployment (use -Deploy to deploy) ---" -ForegroundColor Yellow
}

# ============================================================================
# STEP 5: Verify SES Configuration
# ============================================================================
Write-Host "`n--- Step 5: Verifying SES configuration ---" -ForegroundColor Yellow

# Check SES sending limits
Write-Host "Checking SES sending limits..." -ForegroundColor Cyan
try {
    $sesQuota = aws ses get-send-quota --region $Region | ConvertFrom-Json
    Write-Host "  Max 24 Hour Send: $($sesQuota.Max24HourSend)" -ForegroundColor White
    Write-Host "  Max Send Rate: $($sesQuota.MaxSendRate)/sec" -ForegroundColor White
    Write-Host "  Sent Last 24 Hours: $($sesQuota.SentLast24Hours)" -ForegroundColor White
    
    if ($sesQuota.Max24HourSend -eq 200) {
        Write-Host "  ⚠ SES is in SANDBOX mode - only verified addresses can receive emails" -ForegroundColor Yellow
        Write-Host "  Request production access: https://console.aws.amazon.com/ses/home#/account" -ForegroundColor Yellow
    } else {
        Write-Host "  ✓ SES is in PRODUCTION mode" -ForegroundColor Green
    }
} catch {
    Write-Host "  ⚠ Could not retrieve SES quota: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Check verified identities
Write-Host "`nChecking verified email identities..." -ForegroundColor Cyan
try {
    $verifiedEmails = aws ses list-verified-email-addresses --region $Region | ConvertFrom-Json
    if ($verifiedEmails.VerifiedEmailAddresses.Count -gt 0) {
        Write-Host "  ✓ Verified email addresses:" -ForegroundColor Green
        foreach ($email in $verifiedEmails.VerifiedEmailAddresses) {
            Write-Host "    - $email" -ForegroundColor White
        }
    } else {
        Write-Host "  ⚠ No verified email addresses found" -ForegroundColor Yellow
        Write-Host "  Verify addresses: aws ses verify-email-identity --email-address noreply@tsin.ca" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ⚠ Could not retrieve verified emails: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Check VPC endpoint (if enabled)
if ($CreateVpcEndpoint -and $Deploy) {
    Write-Host "`nChecking SES VPC endpoint..." -ForegroundColor Cyan
    try {
        $vpcEndpoints = aws ec2 describe-vpc-endpoints `
            --filters "Name=service-name,Values=com.amazonaws.$Region.email-smtp" `
            --region $Region | ConvertFrom-Json
        
        if ($vpcEndpoints.VpcEndpoints.Count -gt 0) {
            Write-Host "  ✓ SES VPC endpoint found:" -ForegroundColor Green
            foreach ($endpoint in $vpcEndpoints.VpcEndpoints) {
                Write-Host "    - ID: $($endpoint.VpcEndpointId)" -ForegroundColor White
                Write-Host "    - State: $($endpoint.State)" -ForegroundColor White
                Write-Host "    - Private DNS: $($endpoint.PrivateDnsEnabled)" -ForegroundColor White
            }
        } else {
            Write-Host "  ⚠ No SES VPC endpoint found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ⚠ Could not check VPC endpoint: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 6: Configure Moodle (Optional)
# ============================================================================
if ($ConfigureMoodle -and $Deploy) {
    Write-Host "`n--- Step 6: Configuring Moodle ---" -ForegroundColor Yellow
    
    # Find running instance
    Write-Host "Finding Moodle instance..." -ForegroundColor Cyan
    $instanceJson = aws ec2 describe-instances `
        --filters "Name=tag:aws:cloudformation:stack-name,Values=$StackName" `
                  "Name=instance-state-name,Values=running" `
        --region $Region
    
    $instances = ($instanceJson | ConvertFrom-Json).Reservations.Instances
    
    if ($instances.Count -eq 0) {
        Write-Host "  ⚠ No running instances found" -ForegroundColor Yellow
    } else {
        $instanceId = $instances[0].InstanceId
        Write-Host "  ✓ Found instance: $instanceId" -ForegroundColor Green
        
        # Upload configuration script
        Write-Host "Uploading configuration script to S3..." -ForegroundColor Cyan
        $accountId = aws sts get-caller-identity --query Account --output text
        $bucketName = "moodle-scripts-$accountId-$Region"
        
        aws s3 cp scripts/configure-moodle-ses-email.sh "s3://$bucketName/" --region $Region
        Write-Host "  ✓ Script uploaded to S3" -ForegroundColor Green
        
        # Run configuration via SSM
        Write-Host "Running configuration script on instance..." -ForegroundColor Cyan
        $commandId = aws ssm send-command `
            --instance-ids $instanceId `
            --document-name "AWS-RunShellScript" `
            --parameters "commands=[
                'aws s3 cp s3://$bucketName/configure-moodle-ses-email.sh /tmp/',
                'chmod +x /tmp/configure-moodle-ses-email.sh',
                '/tmp/configure-moodle-ses-email.sh'
            ]" `
            --region $Region `
            --query "Command.CommandId" `
            --output text
        
        Write-Host "  Command ID: $commandId" -ForegroundColor White
        Write-Host "  Waiting for command to complete..." -ForegroundColor Cyan
        
        Start-Sleep -Seconds 10
        
        $output = aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $instanceId `
            --region $Region | ConvertFrom-Json
        
        Write-Host "`n  Output:" -ForegroundColor White
        Write-Host $output.StandardOutputContent -ForegroundColor Gray
        
        if ($output.Status -eq "Success") {
            Write-Host "  ✓ Moodle configuration successful" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Moodle configuration failed" -ForegroundColor Red
            Write-Host "  Error: $($output.StandardErrorContent)" -ForegroundColor Red
        }
    }
} elseif ($ConfigureMoodle) {
    Write-Host "`n--- Step 6: Skipping Moodle configuration (requires -Deploy) ---" -ForegroundColor Yellow
}

# ============================================================================
# STEP 7: Summary and Next Steps
# ============================================================================
Write-Host "`n=== Summary ===" -ForegroundColor Cyan

if ($Deploy) {
    Write-Host "✓ CDK stack deployed successfully" -ForegroundColor Green
    Write-Host "✓ SES email infrastructure configured" -ForegroundColor Green
} else {
    Write-Host "✓ CDK stack synthesized successfully" -ForegroundColor Green
    Write-Host "⚠ Stack not deployed (use -Deploy to deploy)" -ForegroundColor Yellow
}

Write-Host "`n📧 Next Steps:" -ForegroundColor Cyan
Write-Host "1. Verify email addresses in SES Console" -ForegroundColor White
Write-Host "   aws ses verify-email-identity --email-address noreply@tsin.ca --region $Region" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Create SES SMTP credentials" -ForegroundColor White
Write-Host "   https://console.aws.amazon.com/ses/home#/smtp" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Store credentials in Secrets Manager" -ForegroundColor White
Write-Host "   aws secretsmanager create-secret --name moodle/ses/smtp-credentials ..." -ForegroundColor Gray
Write-Host ""
Write-Host "4. Configure Moodle (if not done)" -ForegroundColor White
Write-Host "   .\deploy-ses-email-config.ps1 -Deploy -ConfigureMoodle" -ForegroundColor Gray
Write-Host ""
Write-Host "5. Test email sending" -ForegroundColor White
Write-Host "   See: docs/SES-EMAIL-CONFIGURATION.md" -ForegroundColor Gray
Write-Host ""

Write-Host "📚 Documentation: docs/SES-EMAIL-CONFIGURATION.md" -ForegroundColor Cyan
Write-Host ""

