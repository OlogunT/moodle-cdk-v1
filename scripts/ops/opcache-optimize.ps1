$shellCmd = @'
echo "=== 1. Optimize OPcache settings ==="
cp /etc/php.ini /etc/php.ini.bak.opcache

cat >> /etc/php.d/10-opcache.ini << 'EOFCFG'
; Moodle NFS performance tuning
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
opcache.validate_timestamps=1
opcache.save_comments=1
opcache.enable_cli=0
opcache.file_update_protection=0
opcache.consistency_checks=0
EOFCFG

echo "OPcache config updated"
echo ""
echo "=== 2. Restart PHP-FPM ==="
systemctl restart php-fpm
echo "PHP-FPM restarted"
echo ""
echo "=== 3. Warmup login page ==="
for idx in 1 2 3; do
  curl -s -o /dev/null -w "warmup ${idx}: HTTP=%{http_code} Time=%{time_total}s\n" -m 60 http://localhost/login/index.php 2>&1
done
echo ""
echo "=== 4. Warmup homepage ==="
for idx in 1 2 3; do
  curl -s -o /dev/null -w "warmup ${idx}: HTTP=%{http_code} Time=%{time_total}s\n" -m 60 http://localhost/ 2>&1
done
echo ""
echo "=== 5. OPcache usage after warmup ==="
php -r 'print_r(opcache_get_status(false)["memory_usage"]); echo "\n"; print_r(opcache_get_status(false)["opcache_statistics"]);' 2>&1
echo ""
echo "=== 6. Test admin page ==="
curl -s -o /dev/null -w "admin: HTTP=%{http_code} Time=%{time_total}s\n" -m 180 http://localhost/admin/index.php 2>&1
echo "DONE"
'@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 600 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"

