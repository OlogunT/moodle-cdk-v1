$ErrorActionPreference = 'Stop'
$p = Join-Path $env:TEMP 'verify-final.json'

$bash = @'
# Kill any stuck processes
pkill -9 -f "upgrade.php" 2>/dev/null || true
pkill -9 -f "cron.php" 2>/dev/null || true
sleep 1

CONFIG=/app/moodle/config.php
H=$(grep -m1 "CFG->dbhost" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
U=$(grep -m1 "CFG->dbuser" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
P=$(grep -m1 "CFG->dbpass" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
N=$(grep -m1 "CFG->dbname" "$CONFIG" | sed "s/.*'\([^']*\)'.*/\1/")
DB="mariadb -h $H -u $U -p$P -D $N --connect-timeout=5"

echo "=== DB CONFIG STATE ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== FIX DB version to match disk ==="
$DB -e "UPDATE mdl_config SET value='2025041402.1' WHERE name='version' AND value='2025041402.10';" 2>&1
echo "Rows affected: $?"

echo "=== DB CONFIG AFTER FIX ==="
$DB -e "SELECT name,value FROM mdl_config WHERE name IN ('version','upgraderunning','allversionshash');" 2>&1

echo "=== CHECK moodle_needs_upgrading ==="
timeout 30 php -r "
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');
require_once('/app/moodle/lib/upgradelib.php');
echo 'Needs upgrade: ' . (moodle_needs_upgrading() ? 'YES' : 'NO') . PHP_EOL;
" 2>&1
echo "Exit: $?"

echo "=== Re-enable cron ==="
echo "* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1" | crontab -u apache - 2>&1
crontab -u apache -l 2>&1

echo "=== Speed test ==="
curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s\n" -m 15 http://localhost/login/index.php 2>&1
curl -s -o /dev/null -w "HTTP:%{http_code} T:%{time_total}s\n" -m 15 http://localhost/login/index.php 2>&1

echo "=== D-state check ==="
ps aux | awk '$8 ~ /D/ {print}' || echo "No D-state"

echo "=== DONE ==="
'@

@{ commands = @($bash) } | ConvertTo-Json -Compress | Set-Content $p -Encoding UTF8
$c = (aws --profile tsin-account --region ca-central-1 ssm send-command --instance-ids i-011c65cd247389ee6 --document-name AWS-RunShellScript --parameters "file://$p" --timeout-seconds 60 --query 'Command.CommandId' --output text).Trim()
Write-Host "CID: $c"
Start-Sleep 45
$r = aws --profile tsin-account --region ca-central-1 --cli-read-timeout 60 ssm get-command-invocation --command-id $c --instance-id i-011c65cd247389ee6 --output json | ConvertFrom-Json
Write-Host "S: $($r.Status) RC: $($r.ResponseCode)"
Write-Host $r.StandardOutputContent
if ($r.StandardErrorContent) { Write-Host "ERR: $($r.StandardErrorContent)" }

