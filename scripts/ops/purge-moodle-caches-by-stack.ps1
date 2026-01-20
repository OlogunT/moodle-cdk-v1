Param(
  [Parameter(Mandatory=$true)][string]$Stack,
  [string]$Region = "ca-central-1",
  [int]$TimeoutSeconds = 900
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# Discover instances by stack name (fallback to Project tag for Prod)
$idsText = aws ec2 describe-instances --region $Region `
  --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack `
  Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].InstanceId' --output text
if (-not $idsText) {
  $idsText = aws ec2 describe-instances --region $Region `
    --filters Name=tag:Project,Values=Moodle-CDK `
    Name=instance-state-name,Values=running `
    --query 'Reservations[].Instances[].InstanceId' --output text
}
if (-not $idsText) { throw "No running instances for $Stack (and no Moodle-CDK instances found)." }
$instances = $idsText -split "\s+" | Where-Object { $_ -ne '' }
Write-Host "Instances: $($instances -join ', ')"

# Build params for SSM
$cmds = @(
  "set -e",
  "if [ -x /usr/bin/php ]; then PHP=/usr/bin/php; elif [ -x /usr/bin/php80 ]; then PHP=/usr/bin/php80; else PHP=php; fi",
  "sudo -u apache $PHP /app/moodle/admin/cli/purge_caches.php || true",
  "find /app/moodle/cache -maxdepth 1 -type f -delete 2>/dev/null || true",
  "echo 'Caches purged.'"
)
$paramObj = [ordered]@{ commands = $cmds; executionTimeout = @($TimeoutSeconds.ToString()) }
$tmp = [System.IO.Path]::GetTempFileName()
$json = ($paramObj | ConvertTo-Json -Depth 3)
[System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))

$cmdId = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
  --comment "Purge Moodle caches ($Stack)" --instance-ids $instances --parameters file://$tmp `
  --query 'Command.CommandId' --output text
Write-Host "SSM CommandId: $cmdId"
Start-Sleep -Seconds 5

foreach($id in $instances) {
  Write-Host ("Waiting on {0}" -f $id)
  for ($i=0; $i -lt 60; $i++) {
    $status = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $id --query 'Status' --output text 2>$null
    Write-Host ("[{0}] {1}" -f $i, $status)
    if ($status -in @('Success','Failed','Cancelled','TimedOut')) { break }
    Start-Sleep -Seconds 5
  }
  $stdout = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $id --query 'StandardOutputContent' --output text
  if ($stdout) { Write-Host $stdout }
}
Write-Host "Done."

