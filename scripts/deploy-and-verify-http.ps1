param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "=== BUILD ==="
./node_modules/.bin/tsc -p .

Write-Host "=== DEPLOY ==="
cdk deploy --require-approval never

Write-Host "=== DISCOVER NEW INSTANCE ==="
# Try to get running instance in stack
$desc = aws ec2 describe-instances --region $Region --filters Name=tag:aws:cloudformation:stack-name,Values=$Stack Name=instance-state-name,Values=running | ConvertFrom-Json
$instanceId = $null
foreach ($r in $desc.Reservations) { foreach ($i in $r.Instances) { if ($i.InstanceId) { $instanceId = $i.InstanceId; break } } if ($instanceId) { break } }
if (-not $instanceId) { throw "No running instance found" }
Write-Host "InstanceId: $instanceId"

Write-Host "=== WAIT FOR BOOT/USER-DATA (90s) ==="
Start-Sleep -Seconds 90

Write-Host "=== SSM VERIFY (HTTP no-redirect sanity) ==="
$paramPath = Join-Path $PSScriptRoot 'ssm-verify-apache.json'
if (-not (Test-Path $paramPath)) { throw "Missing $paramPath" }
$cmdId = aws ssm send-command --region $Region --instance-ids $instanceId --document-name AWS-RunShellScript --parameters file://$paramPath --query "Command.CommandId" --output text
Write-Host "CmdId: $cmdId"
Start-Sleep -Seconds 15
$inv = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --output json | ConvertFrom-Json
Write-Host "Status: $($inv.Status)"
$stdout = $inv.StandardOutputContent
$stderr = $inv.StandardErrorContent

$dir = Join-Path $PSScriptRoot 'outputs'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $dir 'verify-stdout.txt'), $stdout, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $dir 'verify-stderr.txt'), $stderr, [System.Text.UTF8Encoding]::new($false))

Write-Host "--- SUMMARY ---"
# Services
$httpdActive = ($stdout -match "\nactive\n") -or ($stdout -match "httpd")
$phpfpmActive = ($stdout -match "php-fpm")
$hasVhost = ($stdout -match "moodle.conf")
$health200 = ($stdout -match "\n200\n")
$configHttp = ($stdout -match "wwwroot.*http://")
$sslproxyFalse = ($stdout -match "sslproxy.*false")
$cookiesecureFalse = ($stdout -match "cookiesecure.*false")
$reverseproxyTrue = ($stdout -match "reverseproxy.*true")
$loginhttpsZero = ($stdout -match "loginhttps.*0")
Write-Host ("services: httpd={0} php-fpm={1} vhost={2}" -f $httpdActive,$phpfpmActive,$hasVhost)
Write-Host ("health200={0} wwwroot_http={1} reverseproxy={2} sslproxy_false={3} cookiesecure_false={4} loginhttps0={5}" -f $health200,$configHttp,$reverseproxyTrue,$sslproxyFalse,$cookiesecureFalse,$loginhttpsZero)
Write-Host ("Stdout saved: {0}" -f (Join-Path $dir 'verify-stdout.txt'))
Write-Host ("Stderr saved: {0}" -f (Join-Path $dir 'verify-stderr.txt'))

