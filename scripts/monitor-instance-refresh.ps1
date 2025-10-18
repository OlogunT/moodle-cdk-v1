param(
  [string]$Region = "ca-central-1",
  [string]$AsgName = "MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu",
  [int]$PollSeconds = 20
)

$ErrorActionPreference = 'Stop'

Write-Host "Monitoring Instance Refresh for ASG: $AsgName"
Write-Host "Region: $Region"
Write-Host "Polling every $PollSeconds seconds..."
Write-Host ""

while ($true) {
  $json = aws autoscaling describe-instance-refreshes `
    --auto-scaling-group-name $AsgName `
    --region $Region `
    --query 'InstanceRefreshes[0]' `
    --output json
  
  $refresh = $json | ConvertFrom-Json
  
  $timestamp = Get-Date -Format 'HH:mm:ss'
  $status = $refresh.Status
  $progress = $refresh.PercentageComplete
  $toUpdate = $refresh.InstancesToUpdate
  
  Write-Host ("{0} | Status: {1} | Progress: {2}% | ToUpdate: {3}" -f $timestamp, $status, $progress, $toUpdate)
  
  if ($status -in @('Successful', 'Failed', 'Cancelled')) {
    Write-Host ""
    Write-Host "Instance Refresh completed with status: $status" -ForegroundColor $(if ($status -eq 'Successful') { 'Green' } else { 'Red' })
    break
  }
  
  Start-Sleep -Seconds $PollSeconds
}

