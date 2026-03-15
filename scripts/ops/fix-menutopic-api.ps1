#!/usr/bin/env pwsh
# Fix menutopic plugin: replace deprecated set_section_number with set_sectionnum
Param(
  [string]$Profile    = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$InstanceId = 'i-011c65cd247389ee6'
)
$ErrorActionPreference = 'Stop'
$awsArgs = @('--profile', $Profile, '--region', $Region, '--cli-read-timeout', '120')

$bash = @'
#!/bin/bash
PLUGIN_DIR=/app/moodle/course/format/menutopic

echo "=== SEARCHING FOR set_section_number IN MENUTOPIC ==="
grep -rn "set_section_number" "$PLUGIN_DIR" 2>&1 || echo "No occurrences found"

echo "=== REPLACING set_section_number WITH set_sectionnum ==="
COUNT=$(grep -rn "set_section_number" "$PLUGIN_DIR" 2>/dev/null | wc -l)
echo "Found $COUNT occurrence(s) to replace"

if [ "$COUNT" -gt 0 ]; then
  find "$PLUGIN_DIR" -type f -name "*.php" | xargs grep -l "set_section_number" 2>/dev/null | while read f; do
    echo "Patching: $f"
    sed -i 's/set_section_number/set_sectionnum/g' "$f"
  done
  echo "Replacement done"
else
  echo "Nothing to replace"
fi

echo "=== VERIFYING PATCH ==="
REMAINING=$(grep -rn "set_section_number" "$PLUGIN_DIR" 2>/dev/null | wc -l)
echo "Remaining occurrences of set_section_number: $REMAINING"

echo "=== SHOWING PATCHED LINES (set_sectionnum) ==="
grep -rn "set_sectionnum" "$PLUGIN_DIR" 2>&1 || echo "No occurrences found"

echo "=== PURGING MOODLE CACHES ==="
php /app/moodle/admin/cli/purge_caches.php 2>&1
echo "Cache purge exit: $?"

echo "=== DONE ==="
'@

$bashFile = Join-Path $env:TEMP 'fix-menutopic-api.sh'
$bash | Set-Content -Path $bashFile -Encoding UTF8 -NoNewline
$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bashFile))

$paramsFile = Join-Path $env:TEMP 'fix-menutopic-api-params.json'
@{ commands = @(
  "printf '%s' '$b64' | base64 -d > /tmp/fix-menutopic-api.sh",
  "chmod +x /tmp/fix-menutopic-api.sh",
  "bash /tmp/fix-menutopic-api.sh"
)} | ConvertTo-Json -Compress | Set-Content -Path $paramsFile -Encoding UTF8

Write-Host "Sending SSM command..."
$cmdId = ((aws @awsArgs ssm send-command `
  --instance-ids $InstanceId --document-name AWS-RunShellScript `
  --parameters "file://$paramsFile" --timeout-seconds 120 `
  --query 'Command.CommandId' --output text)).Trim()
Write-Host "CommandId: $cmdId"

Write-Host "Waiting 40s for command to complete..."
Start-Sleep 40

$result = aws @awsArgs ssm get-command-invocation `
  --command-id $cmdId --instance-id $InstanceId --output json | ConvertFrom-Json

Write-Host "Status: $($result.Status)"
Write-Host "RC: $($result.ResponseCode)"
Write-Host ""
Write-Host "=== STDOUT ==="
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) {
  Write-Host "=== STDERR ==="
  Write-Host $result.StandardErrorContent
}

