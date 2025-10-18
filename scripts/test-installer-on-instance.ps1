param(
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

Write-Host "=== TESTING INSTALLER SCRIPT ON INSTANCE ===" -ForegroundColor Cyan
Write-Host ""

# Get a healthy instance
$instanceId = aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy'].InstanceId | [0]" `
  --output text

if (-not $instanceId -or $instanceId -eq 'None') {
  Write-Host "No healthy instances found" -ForegroundColor Red
  exit 1
}

Write-Host "Testing on instance: $instanceId" -ForegroundColor Green
Write-Host ""

# Read the local script
$scriptContent = Get-Content "scripts/intelligent-moodle-install.sh" -Raw

# Create a test command that uploads and runs the script
$params = @{
  commands = @(
    "echo 'Uploading test version of installer script...'",
    "cat > /tmp/intelligent-moodle-install-test.sh << 'EOFSCRIPT'",
    $scriptContent,
    "EOFSCRIPT",
    "chmod +x /tmp/intelligent-moodle-install-test.sh",
    "echo 'Running syntax check...'",
    "bash -n /tmp/intelligent-moodle-install-test.sh && echo '✓ Syntax check passed' || echo '✗ Syntax check FAILED'",
    "echo ''",
    "echo 'Running installer (this may take a few minutes)...'",
    "export APP_EFS_ID=fs-0deb74464b6b70061",
    "export DATA_EFS_ID=fs-0ba02b764ac5b2ca5",
    "export REGION=ca-central-1",
    "export DB_SECRET_ARN=arn:aws:secretsmanager:ca-central-1:483382415631:secret:MoodleDatabaseSecret-xxxxxxxx",
    "export MOODLE_WWWROOT=https://elearning.tsin.ca",
    "/tmp/intelligent-moodle-install-test.sh 2>&1 | tail -n 100"
  )
} | ConvertTo-Json -Compress

$tmpFile = New-TemporaryFile
[System.IO.File]::WriteAllText($tmpFile.FullName, $params, [System.Text.UTF8Encoding]::new($false))

try {
  Write-Host "Sending command to instance..."
  $cmdId = aws ssm send-command `
    --region $Region `
    --instance-ids $instanceId `
    --document-name AWS-RunShellScript `
    --timeout-seconds 600 `
    --parameters "file://$($tmpFile.FullName)" `
    --query "Command.CommandId" `
    --output text
  
  Write-Host "Command ID: $cmdId"
  Write-Host "Waiting for execution (this may take several minutes)..."
  Write-Host ""
  
  # Wait and poll for completion
  $maxWait = 600
  $waited = 0
  $status = "InProgress"
  
  while ($waited -lt $maxWait -and $status -eq "InProgress") {
    Start-Sleep -Seconds 10
    $waited += 10
    
    $status = aws ssm get-command-invocation `
      --region $Region `
      --command-id $cmdId `
      --instance-id $instanceId `
      --query "Status" `
      --output text 2>$null
    
    Write-Host "[${waited}s] Status: $status"
  }
  
  Write-Host ""
  Write-Host "=== OUTPUT ===" -ForegroundColor Cyan
  
  $output = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $instanceId `
    --query "StandardOutputContent" `
    --output text
  
  Write-Host $output
  
  Write-Host ""
  Write-Host "=== ERRORS (if any) ===" -ForegroundColor Yellow
  
  $errors = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $instanceId `
    --query "StandardErrorContent" `
    --output text
  
  if ($errors) {
    Write-Host $errors
  } else {
    Write-Host "(none)"
  }
  
  Write-Host ""
  if ($output -match "Installation completed successfully|✓ Existing installation verified") {
    Write-Host "✓ INSTALLER TEST SUCCESSFUL" -ForegroundColor Green
    Write-Host "You can now deploy with: npx cdk deploy --require-approval never MoodleCdkStack"
  } else {
    Write-Host "⚠ INSTALLER TEST FAILED OR INCOMPLETE" -ForegroundColor Red
    Write-Host "Review the output above before deploying"
  }
  
} finally {
  Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

