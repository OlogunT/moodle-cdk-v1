param(
  [string]$InstanceId,
  [string]$Region = "ca-central-1"
)

$ErrorActionPreference = 'Stop'

Write-Host "Checking logs on instance: $InstanceId"

# Check if installer log exists
$cmd1 = "ls -lh /var/log/moodle-install.log /var/log/bootstrap-moodle.log /var/log/user-data.log 2>&1"
Write-Host "`nChecking log files..."
$cmdId1 = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters commands="$cmd1" --query "Command.CommandId" --output text
Start-Sleep -Seconds 5
$out1 = aws ssm get-command-invocation --region $Region --command-id $cmdId1 --instance-id $InstanceId --query "StandardOutputContent" --output text
Write-Host $out1

# Check services
$cmd2 = "systemctl is-active httpd php-fpm"
Write-Host "`nChecking services..."
$cmdId2 = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters commands="$cmd2" --query "Command.CommandId" --output text
Start-Sleep -Seconds 5
$out2 = aws ssm get-command-invocation --region $Region --command-id $cmdId2 --instance-id $InstanceId --query "StandardOutputContent" --output text
Write-Host $out2

# Tail installer log
$cmd3 = "tail -n 50 /var/log/moodle-install.log 2>&1 || echo LogNotFound"
Write-Host "`nTail of moodle-install.log:"
$cmdId3 = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters commands="$cmd3" --query "Command.CommandId" --output text
Start-Sleep -Seconds 5
$out3 = aws ssm get-command-invocation --region $Region --command-id $cmdId3 --instance-id $InstanceId --query "StandardOutputContent" --output text
Write-Host $out3

# Check config.php
$cmd4 = "ls -lh /app/moodle/config.php 2>&1 || echo ConfigNotFound"
Write-Host "`nChecking config.php..."
$cmdId4 = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters commands="$cmd4" --query "Command.CommandId" --output text
Start-Sleep -Seconds 5
$out4 = aws ssm get-command-invocation --region $Region --command-id $cmdId4 --instance-id $InstanceId --query "StandardOutputContent" --output text
Write-Host $out4

# Tail bootstrap log
$cmd5 = "tail -n 50 /var/log/bootstrap-moodle.log 2>&1"
Write-Host "`nTail of bootstrap-moodle.log:"
$cmdId5 = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters commands="$cmd5" --query "Command.CommandId" --output text
Start-Sleep -Seconds 5
$out5 = aws ssm get-command-invocation --region $Region --command-id $cmdId5 --instance-id $InstanceId --query "StandardOutputContent" --output text
Write-Host $out5

