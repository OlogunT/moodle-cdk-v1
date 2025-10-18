param(
  [string]$Region = "ca-central-1",
  [string]$AsgName = "MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu",
  [int]$ExpectedCount = 2,
  [int]$MaxWaitSeconds = 600
)

$ErrorActionPreference = 'Stop'

Write-Host "Waiting for $ExpectedCount new instances to launch in ASG: $AsgName"
Write-Host "Max wait: $MaxWaitSeconds seconds"
Write-Host ""

$startTime = Get-Date
$waited = 0

while ($waited -lt $MaxWaitSeconds) {
  $json = aws autoscaling describe-auto-scaling-groups `
    --region $Region `
    --auto-scaling-group-names $AsgName `
    --output json
  
  $asg = $json | ConvertFrom-Json
  $instances = $asg.AutoScalingGroups[0].Instances
  
  $inService = ($instances | Where-Object { $_.LifecycleState -eq 'InService' }).Count
  $total = $instances.Count
  
  $timestamp = Get-Date -Format 'HH:mm:ss'
  Write-Host ("[$timestamp] Instances: {0} total, {1} InService (target: {2})" -f $total, $inService, $ExpectedCount)
  
  if ($inService -ge $ExpectedCount) {
    Write-Host ""
    Write-Host "✓ All $ExpectedCount instances are InService!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Instance IDs:"
    foreach ($inst in $instances) {
      if ($inst.LifecycleState -eq 'InService') {
        Write-Host ("  - {0} ({1})" -f $inst.InstanceId, $inst.HealthStatus) -ForegroundColor Green
      }
    }
    exit 0
  }
  
  Start-Sleep -Seconds 10
  $waited = ((Get-Date) - $startTime).TotalSeconds
}

Write-Host ""
Write-Host "Timeout waiting for instances to become InService" -ForegroundColor Yellow
exit 1

