$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  Write-Error 'AWS CLI not found in PATH'
  exit 1
}

$profiles = @()
try {
  $profiles = aws configure list-profiles
} catch {
  Write-Error "Failed to list profiles: $_"
  exit 1
}

if (-not $profiles -or $profiles.Count -eq 0) {
  Write-Host 'No named AWS CLI profiles found (~/.aws/config).'
  exit 0
}

Write-Host 'Profiles found:'
$profiles | ForEach-Object { Write-Host (" - " + $_) }

Write-Host ''
Write-Host 'Resolving each profile to an AWS Account ID:'
foreach($p in $profiles) {
  try {
    $acct = aws sts get-caller-identity --profile $p --query Account --output text
    $arn  = aws sts get-caller-identity --profile $p --query Arn --output text
    Write-Host (" - {0} -> Account {1} ({2})" -f $p, $acct, $arn)
  } catch {
    Write-Host (" - {0} -> ERROR: {1}" -f $p, $_.Exception.Message)
  }
}

