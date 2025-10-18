param(
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

# Get first healthy instance from ASG
$instanceId = aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy'].InstanceId | [0]" `
  --output text

if (-not $instanceId -or $instanceId -eq 'None') {
  Write-Host "No healthy instances found, trying any instance..." -ForegroundColor Yellow
  $instanceId = aws autoscaling describe-auto-scaling-groups `
    --region $Region `
    --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
    --query "AutoScalingGroups[0].Instances[0].InstanceId" `
    --output text
}

if (-not $instanceId -or $instanceId -eq 'None') {
  Write-Host "No instances found in ASG" -ForegroundColor Red
  exit 1
}

Write-Host "Fixing config.php syntax errors via instance: $instanceId"

# Create JSON parameters file
$params = @{
  commands = @(
    "echo 'Restoring config.php from backup...'",
    "if [ -f /app/moodle/config.php.backup ]; then cp /app/moodle/config.php.backup /app/moodle/config.php; echo 'Restored from backup'; else echo 'No backup found'; fi",
    "echo 'Checking syntax...'",
    "php -l /app/moodle/config.php",
    "echo 'Restarting services...'",
    "systemctl restart php-fpm httpd",
    "echo 'Done'"
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
  Start-Sleep -Seconds 10
  
  $output = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $instanceId `
    --query "StandardOutputContent" `
    --output text
  
  Write-Host "`nOutput:"
  Write-Host $output
  
  if ($output -match "No syntax errors") {
    Write-Host "`n✓ Config.php syntax is now valid" -ForegroundColor Green
  } else {
    Write-Host "`n⚠ Config.php may still have syntax errors" -ForegroundColor Yellow
  }
} finally {
  Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

