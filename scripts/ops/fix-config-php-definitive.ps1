#!/usr/bin/env pwsh
# Definitively fix config.php on EFS:
# 1. Remove duplicate require_once
# 2. Remove duplicate Redis session config
# 3. Add lock_factory correctly
# 4. Check Redis connectivity
# Only needs to run on ONE instance since config.php is on EFS
Param(
  [string]$AwsProfile = 'tsin-account',
  [string]$Region     = 'ca-central-1',
  [string]$TargetInst = 'i-04aa12a6aa64b6e66'
)

$python = @'
import re, sys

cfg_path = '/app/moodle/config.php'
with open(cfg_path, 'r') as f:
    content = f.read()

print("=== Original file ===")
print(content)
print("=== End original ===")

# 1. Remove duplicate require_once lines (keep only the last one)
lines = content.split('\n')
require_once_line = "require_once(__DIR__ . \"/lib/setup.php\");"
require_indices = [i for i, l in enumerate(lines) if require_once_line in l]
print(f"Found {len(require_indices)} require_once lines at indices: {require_indices}")

# Remove all but the last require_once occurrence
for idx in require_indices[:-1]:
    lines[idx] = ''  # blank it out

# 2. Remove duplicate Redis session_handler_class blocks (keep first occurrence)
session_handler_indices = [i for i, l in enumerate(lines) if "session_handler_class" in l]
print(f"Found {len(session_handler_indices)} session_handler_class lines at: {session_handler_indices}")

if len(session_handler_indices) > 1:
    # Keep the first block, remove the second (which is 7 lines: handler+host+port+db+serial+locking+prefix)
    # Find and blank the second block and surrounding empty lines
    second_idx = session_handler_indices[1]
    # blank lines second_idx through second_idx+6
    for i in range(second_idx, min(second_idx + 8, len(lines))):
        if i < len(lines):
            lines[i] = ''

# 3. Remove stale comment about lock_factory
lines = [l for l in lines if '// Use database lock factory' not in l]

# 4. Add lock_factory before the (remaining) require_once line
new_lines = []
lock_factory_added = False
lock_factory_line = "$CFG->lock_factory = 'core\\lock\\db_record_lock_factory';"

for line in lines:
    if require_once_line in line and not lock_factory_added:
        if lock_factory_line not in '\n'.join(new_lines):
            new_lines.append('')
            new_lines.append('// Use database lock factory instead of file (EFS flock is unreliable)')
            new_lines.append(lock_factory_line)
        lock_factory_added = True
    new_lines.append(line)

# Clean up excessive blank lines
result = re.sub(r'\n{3,}', '\n\n', '\n'.join(new_lines))

print("=== New config.php ===")
print(result)
print("=== End new config.php ===")

with open(cfg_path, 'w') as f:
    f.write(result)

print("SUCCESS: config.php written")
'@

$bash = @"
#!/bin/bash
echo "=== Fixing config.php on EFS (affects all instances) ==="
python3 << 'PYEOF'
$python
PYEOF

echo "=== PHP syntax check ==="
php -l /app/moodle/config.php 2>&1

echo "=== Verify lock_factory ==="
grep -n "lock_factory" /app/moodle/config.php || echo "MISSING lock_factory - FAILED"

echo "=== Check Redis connectivity ==="
REDIS_HOST=\$(grep session_redis_host /app/moodle/config.php | head -1 | grep -oP "(?<=>= ').*(?=';)")
echo "Redis host: \$REDIS_HOST"
timeout 5 bash -c "echo -e 'PING\r\n' | nc -w 3 \$REDIS_HOST 6379" 2>&1 && echo "Redis REACHABLE" || echo "Redis UNREACHABLE or timeout"

echo "=== Restart PHP-FPM on this instance ==="
systemctl restart php-fpm && echo "php-fpm restarted OK"

echo "=== Wait 5s then test local response ==="
sleep 5
curl -s -o /dev/null -w "HTTP:%{http_code} Time:%{time_total}s" --max-time 12 "http://\$(hostname -I | awk '{print \$1}')/login/index.php" 2>&1
echo ""
echo "=== DONE ==="
"@

$pf = Join-Path $env:TEMP 'fix-config-definitive.json'
@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content -Path $pf -Encoding UTF8

Write-Host "Sending definitive config.php fix to $TargetInst..."
$id = (aws --profile $AwsProfile --region $Region ssm send-command `
    --instance-ids $TargetInst `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 90 `
    --query 'Command.CommandId' --output text 2>&1 | Out-String).Trim()
Write-Host "CMD: $id"
$id | Set-Content (Join-Path $env:TEMP 'fix-config-definitive-cmd.txt')
Write-Host "Poll in 60 seconds with: poll-definitive-fix.ps1"

