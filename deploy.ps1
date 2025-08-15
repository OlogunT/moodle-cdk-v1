# Moodle CDK Deployment Script
# This script deploys the Moodle infrastructure to AWS

param(
    [Parameter(Mandatory=$false)]
    [string]$Action = "deploy",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
)

Write-Host "Moodle CDK Deployment Script" -ForegroundColor Green
Write-Host "=============================" -ForegroundColor Green

# Check if AWS CLI is configured
try {
    $awsIdentity = aws sts get-caller-identity --output json | ConvertFrom-Json
    Write-Host "AWS Identity: $($awsIdentity.Arn)" -ForegroundColor Yellow
} catch {
    Write-Error "AWS CLI not configured or credentials invalid. Please run 'aws configure' first."
    exit 1
}

# Check if CDK is bootstrapped
Write-Host "Checking CDK bootstrap status..." -ForegroundColor Yellow
try {
    cdk bootstrap --show-template 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CDK not bootstrapped. Bootstrapping now..." -ForegroundColor Yellow
        cdk bootstrap aws://$($awsIdentity.Account)/ca-central-1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "CDK bootstrap failed"
            exit 1
        }
    }
} catch {
    Write-Host "Bootstrapping CDK..." -ForegroundColor Yellow
    cdk bootstrap aws://$($awsIdentity.Account)/ca-central-1
}

switch ($Action.ToLower()) {
    "deploy" {
        Write-Host "Starting CDK deployment..." -ForegroundColor Green
        
        # Build the project
        Write-Host "Building TypeScript..." -ForegroundColor Yellow
        npm run build
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Build failed"
            exit 1
        }
        
        # Deploy the stack
        Write-Host "Deploying Moodle stack..." -ForegroundColor Yellow
        if ($Force) {
            cdk deploy --require-approval never
        } else {
            cdk deploy
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Deployment completed successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Yellow
            Write-Host "1. Wait 5-10 minutes for Moodle 5.0 installation to complete"
            Write-Host "2. Run the URL update script: .\scripts\update-moodle-url.ps1"
            Write-Host "3. Access Moodle using the ALB URL from the outputs above"
            Write-Host "4. Login with username: moodle-admin, password: TempPass123!"
            Write-Host "5. Change the admin password immediately after first login"
            Write-Host ""
            Write-Host "To monitor the installation progress:"
            Write-Host ".\monitor.ps1 -Action logs"
            Write-Host ""
            Write-Host "To check when Moodle is ready:"
            Write-Host ".\monitor.ps1 -Action health"
        } else {
            Write-Error "Deployment failed"
            exit 1
        }
    }
    
    "destroy" {
        Write-Host "WARNING: This will destroy all Moodle infrastructure and data!" -ForegroundColor Red
        if (-not $Force) {
            $confirmation = Read-Host "Are you sure you want to continue? (yes/no)"
            if ($confirmation -ne "yes") {
                Write-Host "Deployment cancelled" -ForegroundColor Yellow
                exit 0
            }
        }
        
        Write-Host "Destroying Moodle stack..." -ForegroundColor Red
        cdk destroy --force
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Stack destroyed successfully!" -ForegroundColor Green
        } else {
            Write-Error "Destroy failed"
            exit 1
        }
    }
    
    "diff" {
        Write-Host "Showing differences..." -ForegroundColor Yellow
        npm run build
        cdk diff
    }
    
    "synth" {
        Write-Host "Synthesizing CloudFormation template..." -ForegroundColor Yellow
        npm run build
        cdk synth
    }
    
    default {
        Write-Host "Usage: .\deploy.ps1 [-Action <deploy|destroy|diff|synth>] [-Force]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Actions:"
        Write-Host "  deploy  - Deploy the Moodle infrastructure (default)"
        Write-Host "  destroy - Destroy all infrastructure and data"
        Write-Host "  diff    - Show differences between current and deployed stack"
        Write-Host "  synth   - Generate CloudFormation template"
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  -Force  - Skip confirmation prompts"
    }
}
