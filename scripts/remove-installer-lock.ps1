param(
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

# Get first instance from ASG
$instanceId = aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[0].InstanceId" `
  --output text

if (-not $instanceId -or $instanceId -eq 'None') {
  Write-Host "No instances found in ASG" -ForegroundColor Red
  exit 1
}

Write-Host "Removing stale installer lock via instance: $instanceId"

# Create JSON parameters file
$params = @{
  commands = @(
    "rm -rf /data/.moodle_installer.lock",
    "echo 'Lock removed'",
    "ls -la /data/ | grep lock || echo 'No lock file found'"
  )
} | ConvertTo-Json -Compress

$tmpFile = New-TemporaryFile
[System.IO.File]::WriteAllText($tmpFile.FullName, $params, [System.Text.UTF8Encoding]::new($false))

try {
  $cmdId = aws ssm send-command `
    --region $Region `
    --instance-ids $instanceId `
    --document-name AWS-RunShellScript `
    --parameters "file://$($tmpFile.FullName)" `
    --query "Command.CommandId" `
    --output text
  
  Write-Host "Command sent: $cmdId"
  Write-Host "Waiting for command to complete..."
  Start-Sleep -Seconds 8
  
  $output = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $instanceId `
    --query "StandardOutputContent" `
    --output text
  
  Write-Host "`nOutput:"
  Write-Host $output
  
  if ($output -match "No lock file found") {
    Write-Host "`n✓ Lock file successfully removed" -ForegroundColor Green
  } else {
    Write-Host "`n⚠ Lock file may still exist" -ForegroundColor Yellow
  }
} finally {
  Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

