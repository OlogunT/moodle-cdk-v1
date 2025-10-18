param(
  [string]$InstanceId,
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

if (-not $InstanceId) {
  $InstanceId = aws autoscaling describe-auto-scaling-groups `
    --region $Region `
    --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
    --query "AutoScalingGroups[0].Instances[0].InstanceId" `
    --output text
}

Write-Host "Checking bootstrap status on instance: $InstanceId" -ForegroundColor Cyan
Write-Host ""

$params = @{
  commands = @(
    "echo '=== BOOTSTRAP LOG (last 30 lines) ==='",
    "tail -n 30 /var/log/bootstrap-moodle.log 2>&1 || echo 'Bootstrap log not found'",
    "echo ''",
    "echo '=== INSTALLER LOG (last 20 lines) ==='",
    "tail -n 20 /var/log/moodle-install.log 2>&1 || echo 'Installer log not found'",
    "echo ''",
    "echo '=== SERVICES ==='",
    "systemctl is-active httpd php-fpm",
    "echo ''",
    "echo '=== CONFIG.PHP SYNTAX ==='",
    "php -l /app/moodle/config.php 2>&1"
  )
} | ConvertTo-Json -Compress

$tmpFile = New-TemporaryFile
[System.IO.File]::WriteAllText($tmpFile.FullName, $params, [System.Text.UTF8Encoding]::new($false))

try {
  $cmdId = aws ssm send-command `
    --region $Region `
    --instance-ids $InstanceId `
    --document-name AWS-RunShellScript `
    --parameters "file://$($tmpFile.FullName)" `
    --query "Command.CommandId" `
    --output text
  
  Write-Host "Command sent: $cmdId"
  Write-Host "Waiting for output..."
  Start-Sleep -Seconds 10
  
  $output = aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $InstanceId `
    --query "StandardOutputContent" `
    --output text
  
  Write-Host $output
} finally {
  Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

