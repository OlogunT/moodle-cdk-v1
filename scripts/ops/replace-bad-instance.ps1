Param(
  [Parameter(Mandatory=$true)][string]$InstanceId,
  [string]$Region = 'ca-central-1',
  [string]$Profile = 'tsin-account'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-AsgNameForInstance($id) {
  $name = aws autoscaling describe-auto-scaling-instances --profile $Profile --region $Region --instance-ids $id --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text
  if (-not $name -or $name -eq 'None') { throw "ASG not found for instance $id" }
  return $name
}

function Get-AsgInstances($asgName) {
  $json = aws autoscaling describe-auto-scaling-groups --profile $Profile --region $Region --auto-scaling-group-names $asgName --output json | ConvertFrom-Json
  return @($json.AutoScalingGroups[0].Instances | ForEach-Object { $_.InstanceId })
}

function Get-IsProtected($asgName, $id) {
  $json = aws autoscaling describe-auto-scaling-groups --profile $Profile --region $Region --auto-scaling-group-names $asgName --output json | ConvertFrom-Json
  $inst = @($json.AutoScalingGroups[0].Instances | Where-Object { $_.InstanceId -eq $id }) | Select-Object -First 1
  if (-not $inst) { return $false }
  return [bool]$inst.ProtectedFromScaleIn
}

$asg = Get-AsgNameForInstance -id $InstanceId
Write-Host "ASG: $asg"

$old = Get-AsgInstances -asgName $asg
Write-Host ("Current ASG instances: " + ($old -join ', '))

if (Get-IsProtected -asgName $asg -id $InstanceId) {
  Write-Host "Disabling scale-in protection on $InstanceId ..."
  aws autoscaling set-instance-protection --profile $Profile --region $Region --auto-scaling-group-name $asg --instance-ids $InstanceId --no-protected-from-scale-in | Out-Null
}

Write-Host "Terminating $InstanceId (ASG will launch a replacement) ..."
aws autoscaling terminate-instance-in-auto-scaling-group --profile $Profile --region $Region --instance-id $InstanceId --should-decrement-desired-capacity false | Out-Null

# Wait until instance is terminated
for($i=1;$i -le 60;$i++){
  try {
    $state = aws ec2 describe-instances --profile $Profile --region $Region --instance-ids $InstanceId --query 'Reservations[].Instances[].State.Name' --output text
  } catch { $state = '' }
  if (-not $state -or $state -match 'shutting-down|terminated') { Write-Host "Instance state: $state"; break }
  Start-Sleep -Seconds 5
}

# Wait for a new instance ID to appear
$newId = ''
for($i=1;$i -le 180;$i++){
  $curr = Get-AsgInstances -asgName $asg
  $diff = @($curr | Where-Object { $old -notcontains $_ })
  if ($diff.Count -ge 1) { $newId = $diff[0]; break }
  Start-Sleep -Seconds 5
}

if ($newId) {
  Write-Host "Replacement instance launched: $newId"
} else {
  Write-Warning "Replacement instance not detected yet; ASG may still be launching."
}

