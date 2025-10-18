param(
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

$instanceId = aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy'].InstanceId | [0]" `
  --output text

Write-Host "Viewing config.php from instance: $instanceId"

$params = @{
  commands = @(
    "head -n 60 /app/moodle/config.php 2>&1",
    "echo ''",
    "echo '=== SYNTAX CHECK ==='",
    "php -l /app/moodle/config.php 2>&1"
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
  
  Start-Sleep -Seconds 8
  
  $output = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $instanceId `
    --query "StandardOutputContent" `
    --output text
  
  # Save to file to avoid encoding issues
  $output | Out-File -FilePath "scripts/outputs/config-check.txt" -Encoding utf8
  Write-Host "Output saved to: scripts/outputs/config-check.txt"
  Write-Host ""
  Get-Content "scripts/outputs/config-check.txt"
} finally {
  Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

