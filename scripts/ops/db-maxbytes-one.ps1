Param(
  [Parameter(Mandatory=$true)][string]$InstanceId,
  [string]$Region = 'ca-central-1',
  [string]$Profile = 'tsin-account'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "Querying DB maxbytes on $InstanceId ..."
$cmdId = aws ssm send-command --profile $Profile --region $Region --document-name AWS-RunShellScript `
  --comment 'Query Moodle maxbytes via DB' --instance-ids $InstanceId `
  --parameters file://scripts/ssm-db-maxbytes.json --query 'Command.CommandId' --output text

# Wait up to 3 minutes
$deadline = (Get-Date).AddMinutes(3)
$status = ''
do {
  try {
    $inv = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $cmdId --instance-id $InstanceId --query '{Status:Status}' --output json | ConvertFrom-Json
    $status = $inv.Status
  } catch { $status = 'Pending' }
  if ($status -in 'Success','Cancelled','Failed','TimedOut') { break }
  Start-Sleep -Seconds 2
} while((Get-Date) -lt $deadline)

$out = aws ssm get-command-invocation --profile $Profile --region $Region --command-id $cmdId --instance-id $InstanceId `
  --query '{StdOut:StandardOutputContent,StdErr:StandardErrorContent,Status:Status}' --output json | ConvertFrom-Json
$val = ($out.StdOut -split "`n") | Where-Object { $_ -match '^maxbytes=' } | Select-Object -First 1
Write-Host ("$InstanceId -> $val")
if ($out.StdErr) { Write-Host '--- StdErr (last 5) ---'; ($out.StdErr -split "`n" | Select-Object -Last 5) | ForEach-Object { Write-Host $_ } }

