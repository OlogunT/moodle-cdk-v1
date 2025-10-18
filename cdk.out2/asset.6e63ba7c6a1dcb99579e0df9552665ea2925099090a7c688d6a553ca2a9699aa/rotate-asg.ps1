param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "Region: $Region  Stack: $Stack"

# Find ASG (by name pattern)
$asgs = aws autoscaling describe-auto-scaling-groups --region $Region | ConvertFrom-Json
$asg = $asgs.AutoScalingGroups | Where-Object { $_.AutoScalingGroupName -like '*MoodleAutoScalingGroup*' -or $_.AutoScalingGroupName -like '*ASG*' } | Select-Object -First 1
if (-not $asg) { throw 'ASG not found (pattern *MoodleAutoScalingGroup*)' }
$asgName = $asg.AutoScalingGroupName
Write-Host "ASG: $asgName"

# Record current instance (if any)
$oldInstanceId = $null
if ($asg.Instances) { $oldInstanceId = ($asg.Instances | Where-Object { $_.LifecycleState -ne 'Terminating' } | Select-Object -First 1).InstanceId }
if ($oldInstanceId) { Write-Host "Old instance: $oldInstanceId" } else { Write-Host 'No old instance detected' }

# Scale out: Max=2, Desired=2
aws autoscaling update-auto-scaling-group --region $Region --auto-scaling-group-name $asgName --max-size 2 --desired-capacity 2 | Out-Null

# Wait for 2 InService instances
Write-Host 'Waiting for 2 InService instances in ASG...'
$timeout = (Get-Date).AddMinutes(15)
$newInstanceId = $null
while ($true) {
  Start-Sleep -Seconds 10
  $asg = (aws autoscaling describe-auto-scaling-groups --region $Region --auto-scaling-group-name $asgName | ConvertFrom-Json).AutoScalingGroups[0]
  $inService = @($asg.Instances | Where-Object { $_.LifecycleState -eq 'InService' })
  $count = $inService.Count
  Write-Host ("InService count: {0}" -f $count)
  if ($count -ge 2) {
    $ids = $inService | ForEach-Object { $_.InstanceId }
    $newInstanceId = ($ids | Where-Object { $_ -ne $oldInstanceId } | Select-Object -First 1)
    break
  }
  if ((Get-Date) -gt $timeout) { throw 'Timeout waiting for 2 InService instances' }
}
Write-Host "New instance candidate: $newInstanceId"

# Verify ALB target health for new instance
$albArn = aws ssm get-parameter --name "/moodle/albArn" --region $Region --query "Parameter.Value" --output text 2>$null
if (-not $albArn) { Write-Host 'WARN: /moodle/albArn not found; skipping TG health check' }
else {
  $tgArns = aws elbv2 describe-target-groups --region $Region --load-balancer-arn $albArn --query "TargetGroups[].TargetGroupArn" --output text
  $tgArn = ($tgArns -split '\s+')[0]
  if ($tgArn) {
    Write-Host "Waiting for target healthy in TG: $tgArn"
    $tTimeout = (Get-Date).AddMinutes(10)
    while ($true) {
      Start-Sleep -Seconds 10
      $th = aws elbv2 describe-target-health --region $Region --target-group-arn $tgArn --query "TargetHealthDescriptions[?Target.Id=='$newInstanceId'].TargetHealth.State" --output text
      Write-Host ("Target health for {0}: {1}" -f $newInstanceId,$th)
      if ($th -eq 'healthy') { break }
      if ((Get-Date) -gt $tTimeout) { Write-Host 'WARN: Timeout waiting for healthy target'; break }
    }
  }
}

# Terminate old instance with decrement to 1
if ($oldInstanceId) {
  Write-Host "Terminating old instance: $oldInstanceId"
  aws autoscaling terminate-instance-in-auto-scaling-group --region $Region --instance-id $oldInstanceId --should-decrement-desired-capacity | Out-Null
}

# Ensure Max back to 1
aws autoscaling update-auto-scaling-group --region $Region --auto-scaling-group-name $asgName --max-size 1 | Out-Null
Write-Host 'Rotation complete.'

