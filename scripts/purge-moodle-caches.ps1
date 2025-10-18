param(
  [string]$Region = "ca-central-1",
  [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-MoodleInstanceIds {
  param([string]$Region)
  $tgArn = aws elbv2 describe-target-groups --region $Region --query "TargetGroups[?starts_with(TargetGroupName, 'Moodle-Moodl-')].TargetGroupArn | [0]" --output text 2>$null
  if (-not $tgArn -or $tgArn -eq 'None') { return @() }
  $ids = aws elbv2 describe-target-health --region $Region --target-group-arn $tgArn --query "TargetHealthDescriptions[].Target.Id" --output text 2>$null
  if (-not $ids) { return @() }
  return $ids -split "`t" | Where-Object { $_ -and $_ -ne 'None' }
}

function Invoke-PurgeCaches {
  param([string]$InstanceId,[string]$Region,[int]$TimeoutSeconds)
  Write-Host ("Purging caches on {0}" -f $InstanceId)
  $cmds = @(
    "set -e",
    "if [ -x /usr/bin/php ]; then PHP=/usr/bin/php; elif [ -x /usr/bin/php80 ]; then PHP=/usr/bin/php80; else PHP=php; fi",
    "sudo -u apache $PHP /app/moodle/admin/cli/purge_caches.php || true",
    "# also clear local cache dir if present (safe)",
    "find /app/moodle/cache -maxdepth 1 -type f -delete 2>/dev/null || true",
    "echo 'Caches purged.'"
  )
  $paramObj = [ordered]@{ commands = $cmds; executionTimeout = @($TimeoutSeconds.ToString()) }
  $tmp = [System.IO.Path]::GetTempFileName()
  $json = ($paramObj | ConvertTo-Json -Depth 3)
  [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
  $cmdId = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters file://$tmp --query "Command.CommandId" --output text
  if (-not $cmdId) { throw "Failed to send SSM command" }
  Write-Host ("SSM CommandId: {0}" -f $cmdId)
  Start-Sleep -Seconds 5
  for ($i=0; $i -lt 60; $i++) {
    $status = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query "Status" --output text 2>$null
    Write-Host ("[{0}] {1}" -f $i, $status)
    if ($status -in @('Success','Failed','Cancelled','TimedOut')) { break }
    Start-Sleep -Seconds 5
  }
  $stdout = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query "StandardOutputContent" --output text
  if ($stdout) { Write-Host $stdout }
}

$ids = Get-MoodleInstanceIds -Region $Region
if (-not $ids -or $ids.Count -eq 0) { Write-Warning "No instances in target group"; exit 2 }
foreach ($id in $ids) {
  Invoke-PurgeCaches -InstanceId $id -Region $Region -TimeoutSeconds $TimeoutSeconds
}
Write-Host "Done."

