param(
  [string]$Region = "ca-central-1"
)
$ErrorActionPreference = 'Stop'
$paramPath = Join-Path $PSScriptRoot 'tmp-ssm-verify-dataroot.json'
if (-not (Test-Path $paramPath)) { throw "Missing $paramPath" }
# Find ASG and one healthy instance
$asg = aws autoscaling describe-auto-scaling-groups --region $Region --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName | [0]" --output text
if (-not $asg -or $asg -eq 'None') { throw 'ASG not found' }
$iid = aws autoscaling describe-auto-scaling-groups --region $Region --auto-scaling-group-names $asg --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy'].InstanceId | [0]" --output text
if (-not $iid -or $iid -eq 'None') { throw 'No healthy instance' }
Write-Host ("Instance: {0}" -f $iid)
$cmdId = aws ssm send-command --region $Region --instance-ids $iid --document-name AWS-RunShellScript --parameters file://$paramPath --query "Command.CommandId" --output text
Start-Sleep -Seconds 8
$out = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $iid --query StandardOutputContent --output text
$err = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $iid --query StandardErrorContent --output text
"==== STDOUT ===="
$out
"==== STDERR ===="
$err

