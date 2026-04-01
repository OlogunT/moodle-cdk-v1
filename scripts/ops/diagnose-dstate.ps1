#!/usr/bin/env pwsh
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
echo "=== UPGRADE PROCESS ==="
UPID=$(pgrep -f "upgrade.php" | head -1)
if [ -z "$UPID" ]; then
  echo "No upgrade.php running"
else
  echo "PID: $UPID"
  echo "State: $(cat /proc/$UPID/status | grep State)"
  echo "Wchan: $(cat /proc/$UPID/wchan 2>/dev/null)"
  
  echo "=== STRACE (5 seconds) ==="
  timeout 5 strace -p $UPID -e trace=all -f 2>&1 | tail -30 || echo "strace done/failed"
  
  echo "=== /proc/$UPID/stack ==="
  cat /proc/$UPID/stack 2>/dev/null || echo "no stack"
  
  echo "=== /proc/$UPID/io ==="
  cat /proc/$UPID/io 2>/dev/null || echo "no io"
  
  echo "=== fd links ==="
  ls -la /proc/$UPID/fd/ 2>/dev/null | tail -20
fi

echo "=== MOUNT POINTS ==="
mount | grep -E "(nfs|efs|fuse|data|moodle)"
df -h /data/moodledata/ 2>/dev/null
df -h /app/moodle/ 2>/dev/null

echo "=== DMESG (last 20 NFS/EFS/IO errors) ==="
dmesg | grep -iE "(nfs|efs|hung|block|I/O|error|timeout)" | tail -20

echo "=== FILESYSTEM CHECK ==="
stat /data/moodledata/ 2>&1
stat /app/moodle/ 2>&1

echo "=== ALL D-STATE PROCESSES ==="
ps aux | awk '$8 ~ /D/ {print}'

echo "=== KILL UPGRADE PROCESS ==="
if [ -n "$UPID" ]; then
  kill -9 $UPID 2>&1
  echo "Killed $UPID"
fi

echo "=== DONE ==="
'@

$paramsFile = Join-Path $env:TEMP 'diag-dstate-params.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 60 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"
Start-Sleep 25
$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status: $($result.Status), RC: $($result.ResponseCode)"
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host "STDERR: $($result.StandardErrorContent)" }

