param(
  [string]$Region = "ca-central-1",
  [string]$NameLike = "*MoodleAutoScalingGroup*",
  [int]$InstanceWarmupSeconds = 180,
  [int]$MinHealthyPercent = 50,
  [int]$PollSeconds = 20,
  [int]$MaxPolls = 60,
  [bool]$SkipMatching = $false
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "Region: $Region"
Write-Host "Looking for ASG like: $NameLike"

$j = aws autoscaling describe-auto-scaling-groups --region $Region --output json | ConvertFrom-Json
$asg = $j.AutoScalingGroups | Where-Object { $_.AutoScalingGroupName -like $NameLike } | Select-Object -First 1
if (-not $asg) { throw "No Auto Scaling Group matching $NameLike found" }
$asgName = $asg.AutoScalingGroupName
Write-Host ("ASG: {0}" -f $asgName)

# Build preferences JSON to temp file
$prefs = @{ InstanceWarmup = $InstanceWarmupSeconds; MinHealthyPercentage = $MinHealthyPercent; SkipMatching = $SkipMatching } | ConvertTo-Json -Compress
$prefFile = New-TemporaryFile
Set-Content -Path $prefFile -Value $prefs -Encoding ascii

Write-Host "Starting Instance Refresh (Rolling)..."
$irId = aws autoscaling start-instance-refresh --auto-scaling-group-name $asgName --strategy Rolling --preferences file://$prefFile --region $Region --query 'InstanceRefreshId' --output text
if (-not $irId) { throw "Failed to start instance refresh" }
Write-Host ("InstanceRefreshId: {0}" -f $irId)

Write-Host "Polling refresh status..."
$desc = $null
for ($i=0; $i -lt $MaxPolls; $i++) {
  $desc = aws autoscaling describe-instance-refreshes --auto-scaling-group-name $asgName --region $Region --query 'InstanceRefreshes[0]' --output json | ConvertFrom-Json
  if ($null -ne $desc) {
    Write-Host ("[{0}/{1}] Status: {2}  Progress: {3}%  ToUpdate: {4}" -f ($i+1),$MaxPolls,$desc.Status,$desc.PercentageComplete,$desc.InstancesToUpdate)
    if ($desc.Status -in @('Successful','Failed','Cancelled')) { break }
  } else {
    Write-Host "No status yet"
  }
  Start-Sleep -Seconds $PollSeconds
}

if ($desc -and $desc.Status -eq 'Successful') {
  Write-Host "Instance Refresh completed successfully." -ForegroundColor Green
  exit 0
} else {
  Write-Host ("Final Status: {0}" -f ($desc.Status)) -ForegroundColor Yellow
  exit 2
}

