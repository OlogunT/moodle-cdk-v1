param(
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

Write-Host "=== RESTORING CONFIG.PHP AND RESTARTING INSTANCES ===" -ForegroundColor Cyan
Write-Host ""

# Get any instance from ASG
$instanceId = aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[0].InstanceId" `
  --output text

if (-not $instanceId -or $instanceId -eq 'None') {
  Write-Host "No instances found in ASG" -ForegroundColor Red
  exit 1
}

Write-Host "Step 1: Restoring config.php from backup via instance: $instanceId"

# Create JSON parameters file
$params = @{
  commands = @(
    "echo 'Checking for backup...'",
    "if [ -f /app/moodle/config.php.backup ]; then",
    "  echo 'Backup found, restoring...'",
    "  cp /app/moodle/config.php.backup /app/moodle/config.php",
    "  chown apache:apache /app/moodle/config.php",
    "  chmod 644 /app/moodle/config.php",
    "  echo 'Restored from backup'",
    "else",
    "  echo 'No backup found - config.php may already be correct'",
    "fi",
    "echo 'Verifying syntax...'",
    "php -l /app/moodle/config.php"
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
  
  Write-Host "  Command sent: $cmdId"
  Start-Sleep -Seconds 10
  
  $output = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $instanceId `
    --query "StandardOutputContent" `
    --output text
  
  Write-Host "  Output: $output"
  
  if ($output -match "No syntax errors") {
    Write-Host "  ✓ Config.php syntax is now valid" -ForegroundColor Green
  } else {
    Write-Host "  ⚠ Config.php may still have issues" -ForegroundColor Yellow
  }
} finally {
  Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Step 2: Terminating all instances to force fresh start with fixed script"

$allInstances = (aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[].InstanceId" `
  --output text).Split("`t")

Write-Host "  Instances to terminate: $($allInstances -join ', ')"

aws ec2 terminate-instances --region $Region --instance-ids $allInstances --output json | Out-Null

Write-Host "  ✓ Instances terminating" -ForegroundColor Green
Write-Host ""
Write-Host "Step 3: Waiting for new instances to launch..."

Start-Sleep -Seconds 30

& "$PSScriptRoot/wait-for-new-instances.ps1" -Region $Region

Write-Host ""
Write-Host "=== COMPLETE ===" -ForegroundColor Green
Write-Host "New instances are running with the fixed installer script."
Write-Host "The update_existing strategy will now skip config.php modifications."

