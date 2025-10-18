#!/bin/bash
set +e

echo "=== QUICK MOODLE DIAGNOSTIC ==="
echo "Time: $(date -u)"
echo ""

echo "=== SERVICES ==="
systemctl is-active httpd
systemctl is-active php-fpm
echo ""

echo "=== MOUNTS ==="
df -h | grep -E "efs|nfs|/app|/data"
echo ""

echo "=== MOODLE FILES ==="
ls -la /app/moodle/config.php 2>&1 | head -5
ls -la /app/moodle/index.php 2>&1 | head -5
echo ""

echo "=== HEALTH CHECK ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost/health
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost/
echo ""

echo "=== APACHE ERROR LOG (last 30 lines) ==="
tail -30 /var/log/httpd/error_log
echo ""

echo "=== MOODLE ERROR LOG (last 30 lines) ==="
tail -30 /var/log/httpd/moodle_error.log
echo ""

echo "=== INSTALL LOG (last 30 lines) ==="
tail -30 /var/log/moodle-install.log
echo ""

echo "=== CONFIG CHECK ==="
if [ -f /app/moodle/config.php ]; then
  echo "config.php exists"
  grep -E "wwwroot|dbhost|dbname" /app/moodle/config.php | head -5
else
  echo "config.php MISSING"
fi
echo ""

echo "=== END DIAGNOSTIC ==="

