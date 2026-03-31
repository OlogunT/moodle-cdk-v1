# deploy-redis-oom-fix.ps1
# Flushes Redis MUC DB via PHP, disables compression, purges caches, restarts PHP-FPM
param(
    [string]$Profile = 'tsin-account',
    [string]$Region  = 'ca-central-1',
    [string[]]$Instances = @('i-08cfb0d5a27e77adb','i-00af3adb301e601f8')
)

$ErrorActionPreference = 'Continue'

$pf = 'C:\Temp\fix-redis-oom2.json'

$commands = @(
    'REDIS_HOST="moo-mo-isf4hcml1bjy.cgt4zg.0001.cac1.cache.amazonaws.com"',
    'echo "=== Step 1: Flush Redis MUC DB 1 via PHP ==="',
    'php -r ''$r=new Redis(); $r->connect("moo-mo-isf4hcml1bjy.cgt4zg.0001.cac1.cache.amazonaws.com",6379); $r->select(1); $b=$r->dbSize(); echo "DB1 keys before: $b\n"; $r->flushDb(); echo "DB1 keys after: ".$r->dbSize()."\n"; echo "MUC_DB_FLUSHED_OK\n";'' 2>&1 || echo "PHP Redis flush failed"',
    'echo "=== Step 2: Find dataroot and MUC config ==="',
    'DATAROOT=$(grep -oP "(?<=dataroot = '\'')[^'\'']*" /app/moodle/config.php 2>/dev/null || echo "/data/moodledata")',
    'echo "dataroot=$DATAROOT"',
    'MUC_CFG="$DATAROOT/muc/config.php"',
    'ls -la "$MUC_CFG" 2>/dev/null || echo "MUC config not found at $MUC_CFG"',
    'echo "=== Step 3: Show compressor setting in MUC config ==="',
    '[ -f "$MUC_CFG" ] && grep -n "compress" "$MUC_CFG" || echo "(no compressor setting in MUC config)"',
    'echo "=== Step 4: Disable compression in MUC config ==="',
    '[ -f "$MUC_CFG" ] && cp "$MUC_CFG" "$MUC_CFG.bak.$(date +%s)" || true',
    '[ -f "$MUC_CFG" ] && sed -i "s/'\''compressor'\'' => '\''[^'\'']*'\''/'\''compressor'\'' => '\''none'\''/g" "$MUC_CFG" && echo "sed done" || true',
    '[ -f "$MUC_CFG" ] && grep -n "compress" "$MUC_CFG" || echo "(no compressor setting after fix)"',
    'echo "=== Step 5: Purge Moodle file caches ==="',
    'sudo -u apache php /app/moodle/admin/cli/purge_caches.php 2>&1 || true',
    'echo "=== Step 6: Restart PHP-FPM ==="',
    'systemctl restart php-fpm && echo "php-fpm restarted OK" || echo "restart failed"',
    'sleep 3',
    'systemctl is-active php-fpm',
    'echo "=== DONE ==="'
)

$payload = @{ commands = $commands } | ConvertTo-Json -Compress
Set-Content $pf $payload -Encoding UTF8
Write-Host "Payload written to $pf"

$results = @()
foreach ($inst in $Instances) {
    $id = (aws --profile $Profile --region $Region --cli-connect-timeout 5 --cli-read-timeout 10 `
        ssm send-command --instance-ids $inst --document-name AWS-RunShellScript `
        --parameters "file://$pf" --timeout-seconds 120 `
        --query 'Command.CommandId' --output text 2>&1).Trim()
    Write-Host "INST:$inst CMD:$id"
    $results += [pscustomobject]@{ inst=$inst; cmd=$id }
}

Write-Host "Waiting 90s for commands to complete..."
Start-Sleep 90

foreach ($pair in $results) {
    Write-Host "`n=== Result: $($pair.inst) ==="
    $r = (aws --profile $Profile --region $Region --cli-connect-timeout 5 --cli-read-timeout 15 `
        ssm get-command-invocation `
        --command-id $pair.cmd `
        --instance-id $pair.inst `
        --query "{Status:Status,RC:ResponseCode,Out:StandardOutputContent,Err:StandardErrorContent}" `
        --output json 2>&1) | Out-String
    ($r -replace '[^\x09\x0A\x0D\x20-\x7E]','?') | Write-Host
}

Write-Host "`n=== External HTTP check ==="
try {
    $r1 = Invoke-WebRequest -Uri "https://elearning.tsin.ca/login/index.php" -TimeoutSec 15 -UseBasicParsing
    Write-Host "Login page: HTTP $($r1.StatusCode)"
} catch { Write-Host "Login page: $($_.Exception.Message)" }

