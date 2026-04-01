# fix-redis-oom.ps1
# Fixes the "Allowed memory size of 4294967296 bytes exhausted" error in redis/lib.php
# caused by a compressed MUC cache object expanding beyond PHP's 4GB memory limit.
# Actions:
#   1. Flushes Redis DB 1 (MUC cache) to evict the bloated key
#   2. Disables compression in the MUC config file if enabled
#   3. Restarts PHP-FPM on all Moodle instances

param(
    [string]$Profile  = 'tsin-account',
    [string]$Region   = 'ca-central-1',
    [string[]]$Instances = @()
)

$ErrorActionPreference = 'Continue'

# Auto-discover running Moodle instances if not provided
if ($Instances.Count -eq 0) {
    Write-Host "Discovering running Moodle instances..."
    $raw = aws --profile $Profile --region $Region --cli-connect-timeout 5 --cli-read-timeout 10 `
        ec2 describe-instances `
        --filters "Name=tag:aws:cloudformation:stack-name,Values=MoodleCdkStack" "Name=instance-state-name,Values=running" `
        --query "Reservations[].Instances[].InstanceId" --output text 2>&1
    if ($raw -match 'i-[0-9a-f]+') {
        $Instances = ($raw -split '\s+') | Where-Object { $_ -match '^i-' }
        Write-Host "Found instances: $($Instances -join ', ')"
    } else {
        Write-Error "Could not discover instances: $raw"
        exit 1
    }
}

# Prepare SSM parameters file
$pf = Join-Path $env:TEMP 'fix-redis-oom.json'
$paramFile = Join-Path $PSScriptRoot '..' 'ssm-fix-redis-oom.json'
if (Test-Path $paramFile) {
    Copy-Item $paramFile $pf -Force
    Write-Host "Using ssm-fix-redis-oom.json"
} else {
    Write-Error "ssm-fix-redis-oom.json not found at $paramFile"
    exit 1
}

# Send command to each instance
$commandIds = @{}
foreach ($inst in $Instances) {
    Write-Host "`n=== Sending fix to $inst ==="
    $id = (aws --profile $Profile --region $Region --cli-connect-timeout 5 --cli-read-timeout 10 `
        ssm send-command `
        --instance-ids $inst `
        --document-name AWS-RunShellScript `
        --parameters "file://$pf" `
        --timeout-seconds 180 `
        --query 'Command.CommandId' --output text 2>&1).Trim()

    if ($id -match '^[0-9a-f\-]{36}$') {
        Write-Host "  CommandId: $id"
        $commandIds[$inst] = $id
    } else {
        Write-Warning "  Failed to send command to $inst : $id"
    }
}

if ($commandIds.Count -eq 0) {
    Write-Error "No commands sent successfully."
    exit 1
}

# Wait and collect results
Write-Host "`nWaiting 90s for commands to complete..."
Start-Sleep 90

foreach ($pair in $commandIds.GetEnumerator()) {
    $inst = $pair.Key
    $cmdId = $pair.Value
    Write-Host "`n=== Result for $inst (cmd: $cmdId) ==="
    $env:PYTHONUTF8 = '1'
    $r = aws --profile $Profile --region $Region --cli-connect-timeout 5 --cli-read-timeout 10 `
        ssm get-command-invocation `
        --command-id $cmdId `
        --instance-id $inst `
        --query "{Status:Status,RC:ResponseCode,Output:StandardOutputContent,Error:StandardErrorContent}" `
        --output json 2>&1 | Out-String
    ($r -replace '[^\x09\x0A\x0D\x20-\x7E]','?') | Write-Host
}

# External verification
Write-Host "`n=== External HTTP check ==="
$login = curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://elearning.tsin.ca/login/index.php" 2>&1
Write-Host "Login page: HTTP $login"

$course = curl -s -L -o /dev/null -w "%{http_code}" --max-time 20 "https://elearning.tsin.ca/course/view.php?id=70" 2>&1
Write-Host "Course 70:  HTTP $course"

