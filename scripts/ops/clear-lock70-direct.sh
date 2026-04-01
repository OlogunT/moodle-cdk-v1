#!/bin/bash
# Clear the stuck cache lock for course 70 - direct DB + file approach
# Does NOT load Moodle PHP (avoids hanging on the stuck lock itself)

echo "=== Parse DB credentials from config.php (python) ==="
eval $(python3 - <<'PYEOF'
import re, sys
cfg = open('/app/moodle/config.php').read()
def get(key):
    m = re.search(r'''\$CFG\s*->\s*''' + key + r'''\s*=\s*['"](.*?)['"]''', cfg)
    return m.group(1) if m else ''
print("DBHOST='%s'" % get('dbhost'))
print("DBNAME='%s'" % get('dbname'))
print("DBUSER='%s'" % get('dbuser'))
print("DBPASS='%s'" % get('dbpass'))
print("PREFIX='%s'" % get('prefix'))
PYEOF
)
echo "host=$DBHOST db=$DBNAME user=$DBUSER prefix=$PREFIX"

echo ""
echo "=== Current lock_db contents ==="
mysql -h "$DBHOST" -u "$DBUSER" -p"$DBPASS" "$DBNAME" \
  -e "SELECT resourcekey, expires, UNIX_TIMESTAMP() as now_ts, (expires - UNIX_TIMESTAMP()) as ttl_sec FROM ${PREFIX}lock_db ORDER BY expires;" 2>&1

echo ""
echo "=== lock_factory in config.php ==="
grep -n "lock_factory" /app/moodle/config.php || echo "MISSING - this is the problem!"

echo ""
echo "=== Delete ALL rows from lock_db (including stuck course 70 lock) ==="
mysql -h "$DBHOST" -u "$DBUSER" -p"$DBPASS" "$DBNAME" \
  -e "DELETE FROM ${PREFIX}lock_db; SELECT ROW_COUNT() as rows_deleted;" 2>&1

echo ""
echo "=== Find + delete file-based lock/cache files for course 70 ==="
find /data/moodledata/cache -name "*70*" -print -delete 2>/dev/null && echo "cache files cleared" || echo "no cache files for 70"
find /data/moodledata/localcache -name "*70*" -print -delete 2>/dev/null && echo "localcache files cleared" || echo "no localcache files for 70"

# Also look for any .lock files that might be from cachestore_file internal locking
echo ""
echo "=== Any .lock files in moodledata ==="
find /data/moodledata -name "*.lock" 2>/dev/null | head -20 || echo "none"

echo ""
echo "=== Restart PHP-FPM to clear OPcache + worker state ==="
systemctl restart php-fpm && echo "php-fpm restarted OK" || echo "FAILED to restart php-fpm"
sleep 4
systemctl is-active php-fpm

echo ""
echo "=== Quick local HTTP test for course 70 ==="
INST_IP=$(hostname -I | awk '{print $1}')
curl -s -o /dev/null -w "HTTP:%{http_code} Time:%{time_total}s" --max-time 15 \
  -H "Host: elearning.tsin.ca" \
  "http://$INST_IP/course/view.php?id=70"
echo ""
echo "=== DONE ==="

