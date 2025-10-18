param(
  [string]$Region = "ca-central-1",
  [int]$CheckIntervalSeconds = 30,
  [int]$MaxChecks = 40
)

$ErrorActionPreference = 'Stop'

function Get-InstanceIds {
  $tgArn = aws elbv2 describe-target-groups --region $Region --query "TargetGroups[?starts_with(TargetGroupName, 'Moodle-Moodl-')].TargetGroupArn | [0]" --output text 2>$null
  if (-not $tgArn -or $tgArn -eq 'None') { return @() }
  $ids = aws elbv2 describe-target-health --region $Region --target-group-arn $tgArn --query "TargetHealthDescriptions[].Target.Id" --output text 2>$null
  if (-not $ids) { return @() }
  return $ids -split "`t" | Where-Object { $_ -and $_ -ne 'None' }
}

function Check-LogFile {
  param([string]$InstanceId, [string]$LogPath)
  
  $cmd = "tail -n 20 $LogPath 2>&1"
  $params = @{
    commands = @($cmd)
  } | ConvertTo-Json -Compress
  
  $tmpFile = New-TemporaryFile
  [System.IO.File]::WriteAllText($tmpFile.FullName, $params, [System.Text.UTF8Encoding]::new($false))
  
  try {
    $cmdId = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters "file://$($tmpFile.FullName)" --query "Command.CommandId" --output text 2>$null
    if (-not $cmdId) { return "SSM command failed" }
    
    Start-Sleep -Seconds 8
    
    $output = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query "StandardOutputContent" --output text 2>$null
    return $output
  } finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Monitoring deployment progress..."
Write-Host "Region: $Region"
Write-Host "Checking every $CheckIntervalSeconds seconds"
Write-Host ""

for ($i = 1; $i -le $MaxChecks; $i++) {
  $timestamp = Get-Date -Format 'HH:mm:ss'
  Write-Host "[$timestamp] Check $i/$MaxChecks" -ForegroundColor Cyan
  
  $instanceIds = Get-InstanceIds
  if ($instanceIds.Count -eq 0) {
    Write-Host "  No instances found in target group yet" -ForegroundColor Yellow
    Start-Sleep -Seconds $CheckIntervalSeconds
    continue
  }
  
  Write-Host "  Found $($instanceIds.Count) instance(s): $($instanceIds -join ', ')"
  
  foreach ($id in $instanceIds) {
    Write-Host "`n  Instance: $id" -ForegroundColor White
    
    # Check if installer log exists and get last few lines
    $installerLog = Check-LogFile -InstanceId $id -LogPath "/var/log/moodle-install.log"
    
    if ($installerLog -match "not found|No such file") {
      Write-Host "    Installer log: NOT YET CREATED (bootstrap still running)" -ForegroundColor Yellow
      
      # Check bootstrap log instead
      $bootstrapLog = Check-LogFile -InstanceId $id -LogPath "/var/log/bootstrap-moodle.log"
      if ($bootstrapLog -and $bootstrapLog.Length -gt 10) {
        $lastLines = ($bootstrapLog -split "`n" | Select-Object -Last 3) -join "`n    "
        Write-Host "    Bootstrap (last 3 lines):`n    $lastLines" -ForegroundColor Gray
      }
    } else {
      Write-Host "    Installer log: EXISTS" -ForegroundColor Green
      if ($installerLog -and $installerLog.Length -gt 10) {
        $lastLines = ($installerLog -split "`n" | Select-Object -Last 3) -join "`n    "
        Write-Host "    Last 3 lines:`n    $lastLines" -ForegroundColor Gray
      }
      
      # Check if installation completed
      if ($installerLog -match "Installation completed successfully|Update completed successfully") {
        Write-Host "    Status: INSTALLATION COMPLETE" -ForegroundColor Green
      } elseif ($installerLog -match "ERROR|FAILED|failed") {
        Write-Host "    Status: ERROR DETECTED" -ForegroundColor Red
      } else {
        Write-Host "    Status: IN PROGRESS" -ForegroundColor Yellow
      }
    }
  }
  
  Write-Host ""
  
  # Check external endpoint
  try {
    $healthResponse = curl -s -o $null -w "%{http_code}" https://elearning.tsin.ca/health 2>$null
    $homeResponse = curl -s -o $null -w "%{http_code}" https://elearning.tsin.ca/ 2>$null
    Write-Host "  External endpoints: Health=$healthResponse | Home=$homeResponse" -ForegroundColor $(if ($homeResponse -eq "200" -or $homeResponse -eq "303") { 'Green' } else { 'Yellow' })
  } catch {
    Write-Host "  External endpoints: Unable to check" -ForegroundColor Gray
  }
  
  Write-Host "`n" + ("=" * 80)
  
  # Check if all instances are done
  $allDone = $true
  foreach ($id in $instanceIds) {
    $check = Check-LogFile -InstanceId $id -LogPath "/var/log/moodle-install.log"
    if ($check -match "not found|No such file" -or -not ($check -match "Installation completed successfully|Update completed successfully")) {
      $allDone = $false
      break
    }
  }
  
  if ($allDone) {
    Write-Host "`n✓ All instances have completed installation!" -ForegroundColor Green
    break
  }
  
  if ($i -lt $MaxChecks) {
    Start-Sleep -Seconds $CheckIntervalSeconds
  }
}

Write-Host "`nMonitoring complete."

