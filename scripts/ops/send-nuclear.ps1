#!/usr/bin/env pwsh
# Just send the nuclear restart to both instances and print command IDs
Param(
  [string]$Profile = 'tsin-account',
  [string]$Region  = 'ca-central-1'
)
$pf = Join-Path $env:TEMP 'nuclear-restart.json'
Write-Host "Params: $pf (exists=$(Test-Path $pf))"

foreach ($inst in @('i-084e9f7a365ea3326', 'i-04aa12a6aa64b6e66')) {
    $raw = aws --profile $Profile --region $Region ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 120 `
        --query 'Command.CommandId' --output text 2>&1
    $id = ($raw | Out-String).Trim()
    Write-Host "INST:$inst CMD:$id"
}
Write-Host "All sent."

