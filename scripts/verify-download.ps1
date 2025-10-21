#!/usr/bin/env pwsh
param(
    [string]$CommandId = "4ae5b87d-5f44-434f-ab5d-c4cccdf42b6b",
    [string]$InstanceId = "i-06e7f96652b2b9620",
    [string]$Region = "ca-central-1"
)

Write-Output "Checking command status..."
$status = & aws ssm get-command-invocation --command-id $CommandId --instance-id $InstanceId --region $Region --query "Status" --output text
Write-Output "Status: $status"
Write-Output ""

if ($status -eq "Success") {
    Write-Output "Command completed successfully!"
    Write-Output ""
    Write-Output "Sending verification command..."
    
    $verifyCmd = & aws ssm send-command --instance-ids $InstanceId --document-name "AWS-RunShellScript" --parameters 'commands=["ls -lh /data/training-backups/","df -h /data"]' --region $Region --output json | ConvertFrom-Json
    
    $verifyCmdId = $verifyCmd.Command.CommandId
    Write-Output "Verify command ID: $verifyCmdId"
    
    Start-Sleep -Seconds 10
    
    $verifyOutput = & aws ssm get-command-invocation --command-id $verifyCmdId --instance-id $InstanceId --region $Region --query "StandardOutputContent" --output text
    
    Write-Output ""
    Write-Output "=== Verification Output ==="
    Write-Output $verifyOutput
}

