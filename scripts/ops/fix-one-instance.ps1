Param(
  [Parameter(Mandatory=$true)][string]$InstanceId,
  [string]$Region = 'ca-central-1',
  [string]$Profile = 'tsin-account'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Wait-SSM {
  Param(
    [Parameter(Mandatory=$true)][string]$CommandId,
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [Parameter(Mandatory=$true)][string]$Region,
    [Parameter(Mandatory=$true)][string]$Profile,
    [int]$TimeoutSeconds = 600
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $status = 'Pending'
  do {
    try {
      $inv = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $CommandId --instance-id $InstanceId --query '{Status:Status}' --output json | ConvertFrom-Json
      $status = $inv.Status
    } catch { $status = 'Pending' }
    if ($status -in 'Success','Cancelled','Failed','TimedOut') { break }
    Start-Sleep -Seconds 2
  } while((Get-Date) -lt $deadline)
  return $status
}

Write-Host "Applying upload limits to $InstanceId ..."
$cmdId = aws ssm send-command --profile $Profile --region $Region --document-name AWS-RunShellScript `
  --comment "Set 1GiB upload limits (single instance)" --instance-ids $InstanceId `
  --parameters file://scripts/ssm-set-upload-limits.json --query 'Command.CommandId' --output text

$status = Wait-SSM -CommandId $cmdId -InstanceId $InstanceId -Region $Region -Profile $Profile -TimeoutSeconds 900

$out = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $cmdId --instance-id $InstanceId `
  --query '{StdOut:StandardOutputContent,StdErr:StandardErrorContent,Status:Status}' --output json | ConvertFrom-Json
Write-Host "Status: $($out.Status)"
Write-Host '--- Key lines ---'
($out.StdOut -split "`n") | Where-Object { $_ -match 'upload_max_filesize|post_max_size|memory_limit|LimitRequestBody|ProxyTimeout|Timeout|maxbytes' } | ForEach-Object { Write-Host $_ }
if ($out.StdErr) { Write-Host '--- StdErr (last 10) ---'; ($out.StdErr -split "`n" | Select-Object -Last 10) | ForEach-Object { Write-Host $_ } }

