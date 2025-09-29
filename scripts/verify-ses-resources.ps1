#!/usr/bin/env pwsh
# Verify SES resources in synthesized CloudFormation template

$ErrorActionPreference = 'Stop'

Write-Host "`n=== Verifying SES Resources in CDK Template ===" -ForegroundColor Cyan

$templatePath = "cdk.out/MoodleCdkStack.template.json"

if (-not (Test-Path $templatePath)) {
    Write-Host "✗ Template not found: $templatePath" -ForegroundColor Red
    Write-Host "Run 'cdk synth MoodleCdkStack' first" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Template found: $templatePath" -ForegroundColor Green

# Load template
$template = Get-Content $templatePath -Raw | ConvertFrom-Json

# Find SES-related resources
Write-Host "`nSearching for SES-related resources..." -ForegroundColor Cyan

$sesResources = @()
foreach ($prop in $template.Resources.PSObject.Properties) {
    if ($prop.Name -like "*Ses*" -or $prop.Name -like "*Email*") {
        $sesResources += [PSCustomObject]@{
            Name = $prop.Name
            Type = $prop.Value.Type
        }
    }
}

if ($sesResources.Count -gt 0) {
    Write-Host "`n✓ Found $($sesResources.Count) SES-related resources:" -ForegroundColor Green
    foreach ($resource in $sesResources) {
        Write-Host "  - $($resource.Name): $($resource.Type)" -ForegroundColor White
    }
} else {
    Write-Host "`n⚠ No SES resources found in template" -ForegroundColor Yellow
}

# Check for SSM parameters
Write-Host "`nSearching for SES SSM parameters..." -ForegroundColor Cyan
$sesParams = @()
foreach ($prop in $template.Resources.PSObject.Properties) {
    if ($prop.Value.Type -eq "AWS::SSM::Parameter" -and 
        $prop.Value.Properties.Name -like "*/ses/*") {
        $sesParams += [PSCustomObject]@{
            LogicalId = $prop.Name
            ParameterName = $prop.Value.Properties.Name
            Value = $prop.Value.Properties.Value
        }
    }
}

if ($sesParams.Count -gt 0) {
    Write-Host "✓ Found $($sesParams.Count) SES SSM parameters:" -ForegroundColor Green
    foreach ($param in $sesParams) {
        Write-Host "  - $($param.ParameterName): $($param.Value)" -ForegroundColor White
    }
} else {
    Write-Host "⚠ No SES SSM parameters found" -ForegroundColor Yellow
}

# Check for SES VPC Endpoint
Write-Host "`nSearching for SES VPC Endpoint..." -ForegroundColor Cyan
$vpcEndpoint = $null
foreach ($prop in $template.Resources.PSObject.Properties) {
    if ($prop.Value.Type -eq "AWS::EC2::VPCEndpoint") {
        $serviceName = $prop.Value.Properties.ServiceName
        if ($serviceName -like "*email-smtp*") {
            $vpcEndpoint = $prop
            break
        }
    }
}

if ($vpcEndpoint) {
    Write-Host "✓ Found SES VPC Endpoint: $($vpcEndpoint.Name)" -ForegroundColor Green
    Write-Host "  Service: $($vpcEndpoint.Value.Properties.ServiceName)" -ForegroundColor White
    Write-Host "  Private DNS: $($vpcEndpoint.Value.Properties.PrivateDnsEnabled)" -ForegroundColor White
} else {
    Write-Host "⚠ No SES VPC Endpoint found (may be conditional)" -ForegroundColor Yellow
}

# Check for IAM permissions
Write-Host "`nSearching for SES IAM permissions..." -ForegroundColor Cyan
$sesPermissions = @()
foreach ($prop in $template.Resources.PSObject.Properties) {
    if ($prop.Value.Type -eq "AWS::IAM::Policy") {
        $policyDoc = $prop.Value.Properties.PolicyDocument
        if ($policyDoc.Statement) {
            foreach ($statement in $policyDoc.Statement) {
                if ($statement.Action) {
                    $sesActions = $statement.Action | Where-Object { $_ -like "ses:*" }
                    if ($sesActions) {
                        $sesPermissions += [PSCustomObject]@{
                            PolicyName = $prop.Name
                            Actions = ($sesActions -join ", ")
                        }
                    }
                }
            }
        }
    }
}

if ($sesPermissions.Count -gt 0) {
    Write-Host "✓ Found SES IAM permissions:" -ForegroundColor Green
    foreach ($perm in $sesPermissions) {
        Write-Host "  - $($perm.PolicyName): $($perm.Actions)" -ForegroundColor White
    }
} else {
    Write-Host "⚠ No SES IAM permissions found" -ForegroundColor Yellow
}

# Check CloudFormation outputs
Write-Host "`nSearching for SES outputs..." -ForegroundColor Cyan
$sesOutputs = @()
foreach ($prop in $template.Outputs.PSObject.Properties) {
    if ($prop.Name -like "*Ses*" -or $prop.Name -like "*Email*") {
        $sesOutputs += [PSCustomObject]@{
            Name = $prop.Name
            Description = $prop.Value.Description
        }
    }
}

if ($sesOutputs.Count -gt 0) {
    Write-Host "✓ Found $($sesOutputs.Count) SES outputs:" -ForegroundColor Green
    foreach ($output in $sesOutputs) {
        Write-Host "  - $($output.Name): $($output.Description)" -ForegroundColor White
    }
} else {
    Write-Host "⚠ No SES outputs found" -ForegroundColor Yellow
}

# Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$totalSesItems = $sesResources.Count + $sesParams.Count + $sesPermissions.Count + $sesOutputs.Count
if ($vpcEndpoint) { $totalSesItems++ }

if ($totalSesItems -gt 0) {
    Write-Host "✓ Found $totalSesItems SES-related items in template" -ForegroundColor Green
    Write-Host "✓ CDK stack is ready for deployment" -ForegroundColor Green
} else {
    Write-Host "✗ No SES configuration found in template" -ForegroundColor Red
    Write-Host "Please verify the CDK stack modifications" -ForegroundColor Yellow
}

Write-Host ""

