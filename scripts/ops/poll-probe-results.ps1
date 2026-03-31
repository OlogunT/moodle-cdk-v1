#!/usr/bin/env pwsh
# Poll results from probe-all-instances.ps1
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1',
  [string]$CmdId   = ''
)
if (-not $CmdId) {
    $CmdId = (Get-Content (Join-Path $env:TEMP 'probe-cmd-id.txt') -ErrorAction Stop).Trim()
}
Write-Host "Polling cmd: $CmdId"

$candidates = @(
  'i-0527f81ac3fde0ec3','i-076b687e9bf43a1a4','i-0ac15d6e22f204649',
  'i-0dca2f988e797653f','i-005355f82b1206aff','i-0f3e2ff1be8ff986a',
  'i-0080670f33aeddd08','i-04ee31773fdaa5a5c','i-03c8a62253d2a10a4',
  'i-0bdae18253da2e0c4','i-09c83f782d36e0f40','i-0a7ec1da61c80bdeb'
)

foreach ($inst in $candidates) {
    $r = aws --profile $Profile --region $Region ssm get-command-invocation `
        --command-id $CmdId --instance-id $inst `
        --query '{S:Status,RC:ResponseCode,O:StandardOutputContent}' `
        --output json 2>&1 | ConvertFrom-Json
    $firstLine = ($r.O -split "`n")[0]
    Write-Host "$inst : $($r.S) | $firstLine"
}

