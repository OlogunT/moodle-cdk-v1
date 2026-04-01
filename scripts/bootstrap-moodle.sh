#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/bootstrap-moodle.log | logger -t bootstrap-moodle -s 2>/dev/console) 2>&1

# Required env vars exported by UserData before calling this script:
# APP_EFS_ID, DATA_EFS_ID, REGION, DB_SECRET_ARN, EFS_SG_ID, MOODLE_WWWROOT (optional)
: "${APP_EFS_ID:?missing}" "${DATA_EFS_ID:?missing}" "${REGION:?missing}" "${DB_SECRET_ARN:?missing}" "${EFS_SG_ID:?missing}"

SCRIPT_BUCKET=${SCRIPT_BUCKET:-"moodle-scripts-$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .accountId)-${REGION}"}

TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds:21600 || true)
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id || true)
ASG_NAME=$(aws autoscaling describe-auto-scaling-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "AutoScalingInstances[0].AutoScalingGroupName" --output text 2>/dev/null || echo "")
[ -n "$ASG_NAME" ] && aws autoscaling set-instance-protection --instance-ids "$INSTANCE_ID" --auto-scaling-group-name "$ASG_NAME" --protected-from-scale-in --region "$REGION" || true

yum update -y
# Base tools
yum install -y amazon-cloudwatch-agent git mariadb105 jq awscli httpd php php-mysqlnd php-gd php-xml php-mbstring php-json php-zip php-curl php-intl php-soap php-ldap php-opcache php-fpm php-redis cronie

# Install and configure cron for Moodle
echo "=== Installing and configuring cron ==="
yum install -y cronie
systemctl start crond
systemctl enable crond
# Configure Moodle cron to run every minute as apache user
echo '* * * * * /usr/bin/php /app/moodle/admin/cli/cron.php >/dev/null 2>&1' | crontab -u apache -
echo "Cron installed and configured for Moodle"

# Configure PHP-FPM (production)
cat > /etc/php-fpm.d/www.conf <<'EOFPHP'
[www]
user = apache
group = apache
listen = /run/php-fpm/www.sock
listen.owner = apache
listen.group = apache
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 1000
request_terminate_timeout = 600
request_slowlog_timeout = 10s
slowlog = /var/log/php-fpm/www-slow.log
catch_workers_output = yes
pm.status_path = /php-fpm-status
ping.path = /php-fpm-ping
ping.response = pong
php_admin_value[error_log] = /var/log/php-fpm/www-error.log
php_admin_flag[log_errors] = on
EOFPHP
mkdir -p /var/log/php-fpm && chown apache:apache /var/log/php-fpm

# PHP ini
cat > /etc/php.d/99-moodle.ini <<'EOFPHPINI'
max_execution_time = 600
max_input_time = 900
memory_limit = 4096M
post_max_size = 1024M
upload_max_filesize = 1024M
max_input_vars = 5000
EOFPHPINI

# Apache vhost
cat > /etc/httpd/conf.d/moodle.conf <<'EOFV'
<VirtualHost *:80>
  DocumentRoot /app/moodle
  DirectoryIndex index.php index.html
  LimitRequestBody 0
  <FilesMatch \.php$>
    SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
  </FilesMatch>
  ProxyTimeout 600
  Timeout 600
  <Directory /app/moodle>
    AllowOverride All
    Require all granted
    Options -Indexes +FollowSymLinks
  </Directory>
  ErrorLog /var/log/httpd/moodle_error.log
  CustomLog /var/log/httpd/moodle_access.log combined
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOFV

# Early health endpoints
mkdir -p /app/moodle
echo OK > /app/moodle/health
cat > /app/moodle/health.php <<'EOFH'
<?php
$start = microtime(true); $healthy = true; $errors=[]; $warnings=[];
if (!function_exists('phpversion')) { $healthy=false; $errors[]='PHP not functioning'; } else { $warnings[]='PHP '.phpversion().' OK'; }
if (function_exists('php_sapi_name') && php_sapi_name()!=='fpm-fcgi') { $warnings[]='Not using PHP-FPM'; }
$elapsed = microtime(true)-$start; if ($elapsed>5) { $healthy=false; $errors[]='Response too slow: '.round($elapsed,2).'s'; }
if (file_exists('/app/moodle/config.php')) { try { $cfg=file_get_contents('/app/moodle/config.php'); if (preg_match("/\$CFG->dbhost\s*=\s*['\"]([^'\"]+)['\"]/",$cfg,$m1)) { $dbhost=$m1[1]; if(preg_match("/\$CFG->dbname\s*=\s*['\"]([^'\"]+)['\"]/",$cfg,$m2)){ $dbname=$m2[1]; if(preg_match("/\$CFG->dbuser\s*=\s*['\"]([^'\"]+)['\"]/",$cfg,$m3)){ $dbuser=$m3[1]; if(preg_match("/\$CFG->dbpass\s*=\s*['\"]([^'\"]+)['\"]/",$cfg,$m4)){ $dbpass=$m4[1]; try { $pdo=new PDO("mysql:host=$dbhost;dbname=$dbname",$dbuser,$dbpass,[PDO::ATTR_TIMEOUT=>2,PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]); $pdo->query('SELECT 1'); $warnings[]='DB OK'; } catch(Exception $e){ $healthy=false; $errors[]='DB connection failed: '.$e->getMessage(); } } } } } } catch(Exception $e){ $warnings[]='DB test skipped: '.$e->getMessage(); } }
if ($healthy) { http_response_code(200); echo 'OK'; if(!empty($warnings)) echo ' ('.implode(', ',$warnings).')'; } else { http_response_code(503); echo 'UNHEALTHY: '.implode(', ',$errors); }
echo ' ['.round((microtime(true)-$start)*1000,2).'ms]';
?>
EOFH
chown apache:apache /app/moodle/health /app/moodle/health.php || true
chmod 644 /app/moodle/health.php || true
systemctl enable httpd && systemctl enable php-fpm || true
systemctl restart httpd && systemctl restart php-fpm || true

# CloudWatch Agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'EOFCW'
{
  "agent": {"metrics_collection_interval": 60, "run_as_user": "root"},
  "logs": {"logs_collected": {"files": {"collect_list": [
    {"file_path": "/var/log/httpd/error_log", "log_group_name": "/aws/ec2/moodle", "log_stream_name": "{instance_id}/apache-error", "timezone": "UTC"},
    {"file_path": "/var/log/httpd/moodle_error.log", "log_group_name": "/aws/ec2/moodle", "log_stream_name": "{instance_id}/moodle-error", "timezone": "UTC"},
    {"file_path": "/var/log/php-fpm/www-slow.log", "log_group_name": "/aws/ec2/moodle", "log_stream_name": "{instance_id}/php-fpm-slow", "timezone": "UTC"},
    {"file_path": "/var/log/php-fpm/www-error.log", "log_group_name": "/aws/ec2/moodle", "log_stream_name": "{instance_id}/php-fpm-error", "timezone": "UTC"}
  ]}}},
  "metrics": {"namespace": "Moodle", "metrics_collected": {
    "cpu": {"measurement": [{"name":"cpu_usage_idle","rename":"CPU_IDLE","unit":"Percent"},{"name":"cpu_usage_iowait","rename":"CPU_IOWAIT","unit":"Percent"}], "metrics_collection_interval":60, "totalcpu":false},
    "mem": {"measurement": [{"name":"mem_used_percent","rename":"MEM_USED","unit":"Percent"}], "metrics_collection_interval":60},
    "processes": {"measurement": [{"name":"running","rename":"PHP_FPM_PROCESSES","unit":"Count"}], "metrics_collection_interval":60}
  }, "append_dimensions": {"InstanceId":"${aws:InstanceId}", "AutoScalingGroupName":"${aws:AutoScalingGroupName}"}}
}
EOFCW
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json || true

# EFS utils and mounts
yum install -y amazon-efs-utils nfs-utils
for fs in "$APP_EFS_ID" "$DATA_EFS_ID"; do
  echo "Waiting for EFS $fs mount targets & SG readiness..."
  for i in $(seq 1 60); do
    MT_JSON=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$fs" 2>/dev/null || true)
    MT_IDS=$(echo "$MT_JSON" | jq -r ".MountTargets[].MountTargetId" 2>/dev/null || true)
    READY=1
    for mt in $MT_IDS; do
      SGL=$(aws efs describe-mount-target-security-groups --region "$REGION" --mount-target-id "$mt" --query "SecurityGroups" --output text 2>/dev/null || true)
      echo "$SGL" | grep -q "$EFS_SG_ID" || READY=0
    done
    [ "$READY" = "1" ] && [ -n "$MT_IDS" ] && break
    sleep 10
  done
done
mkdir -p /app /data
if command -v mount.efs >/dev/null 2>&1; then MOUNT_OPTS="-t efs -o tls,iam"; else MOUNT_OPTS="-t nfs4 -o nfsvers=4.1,noresvport,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"; fi
for i in $(seq 1 60); do mountpoint -q /app && break; echo "[Attempt $i] Mounting /app"; mount $MOUNT_OPTS "$APP_EFS_ID:/" /app || mount $MOUNT_OPTS "$APP_EFS_ID.efs.$REGION.amazonaws.com:/" /app || true; sleep 10; done
for i in $(seq 1 60); do mountpoint -q /data && break; echo "[Attempt $i] Mounting /data"; mount $MOUNT_OPTS "$DATA_EFS_ID:/" /data || mount $MOUNT_OPTS "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/" /data || true; sleep 10; done
if command -v mount.efs >/dev/null 2>&1; then
  grep -qE "^$APP_EFS_ID.efs.$REGION.amazonaws.com:/\s+/app\s+efs" /etc/fstab || echo "$APP_EFS_ID.efs.$REGION.amazonaws.com:/ /app efs _netdev,tls,iam 0 0" >> /etc/fstab
  grep -qE "^$DATA_EFS_ID.efs.$REGION.amazonaws.com:/\s+/data\s+efs" /etc/fstab || echo "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/ /data efs _netdev,tls,iam 0 0" >> /etc/fstab
else
  grep -qE "^$APP_EFS_ID.efs.$REGION.amazonaws.com:/\s+/app\s+nfs4" /etc/fstab || echo "$APP_EFS_ID.efs.$REGION.amazonaws.com:/ /app nfs4 nfsvers=4.1,_netdev 0 0" >> /etc/fstab
  grep -qE "^$DATA_EFS_ID.efs.$REGION.amazonaws.com:/\s+/data\s+nfs4" /etc/fstab || echo "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/ /data nfs4 nfsvers=4.1,_netdev 0 0" >> /etc/fstab
fi

echo "EFS mount verification:"; df -h | grep efs || true; ls -la /app /data || true
mkdir -p /app/moodle; echo OK > /app/moodle/health; cat > /app/moodle/health.php <<'EOFH'
<?php http_response_code(200); echo "OK"; ?>
EOFH
chown apache:apache /app/moodle/health /app/moodle/health.php || true

echo "Downloading intelligent installer from S3..."
for i in $(seq 1 30); do
  if aws s3 cp "s3://$SCRIPT_BUCKET/intelligent-moodle-install.sh" /tmp/intelligent-moodle-install.sh 2>/dev/null; then
    break
  fi
  echo "[Attempt $i/30] intelligent-moodle-install.sh not available yet; retrying in 10s"
  sleep 10
done
if [ ! -s /tmp/intelligent-moodle-install.sh ]; then
  echo "ERROR: intelligent-moodle-install.sh could not be downloaded from S3"; exit 1
fi
chmod +x /tmp/intelligent-moodle-install.sh
INSTALL_SUCCESS=false
if /tmp/intelligent-moodle-install.sh; then
  echo "Installer succeeded"; INSTALL_SUCCESS=true
  [ -n "$ASG_NAME" ] && aws autoscaling set-instance-protection --instance-ids "$INSTANCE_ID" --auto-scaling-group-name "$ASG_NAME" --no-protected-from-scale-in --region "$REGION" || true
else
  echo "Installer failed, will try fallback configuration"; INSTALL_SUCCESS=false
fi

# Post-install: Redis + reverse proxy config
echo "=== POST-INSTALL CONFIG START ==="
# Prefer env-provided REDIS_ENDPOINT, fallback to SSM parameter
if [ -z "${REDIS_ENDPOINT:-}" ]; then
  REDIS_ENDPOINT=$(aws ssm get-parameter --name "/moodle/redis/endpoint" --region "$REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "")
fi
CONFIG_NEEDS_REBUILD=false
CURRENT_REDIS=""
if [ -f "/app/moodle/config.php" ]; then
  CURRENT_REDIS=$(sed -n "s/^\s*\$CFG->session_redis_host\s*=\s*'\(.*\)'.*$/\1/p" /app/moodle/config.php | head -n1 || true)
fi
if [ "$INSTALL_SUCCESS" = "true" ] && [ -f "/app/moodle/config.php" ]; then
  if [ -n "$REDIS_ENDPOINT" ]; then
    if ! grep -q "session_handler_class.*redis" /app/moodle/config.php; then CONFIG_NEEDS_REBUILD=true; fi
    if [ -n "$CURRENT_REDIS" ] && [ "$CURRENT_REDIS" != "$REDIS_ENDPOINT" ]; then CONFIG_NEEDS_REBUILD=true; fi
  fi
else
  CONFIG_NEEDS_REBUILD=true
fi
if [ "$CONFIG_NEEDS_REBUILD" = "true" ] && [ -n "$REDIS_ENDPOINT" ]; then
  echo "Updating config.php to use Redis: $REDIS_ENDPOINT (previous: ${CURRENT_REDIS:-none})"
  cp /app/moodle/config.php /app/moodle/config.php.backup.redis.$(date +%s) || true
  if grep -q "^\s*\$CFG->session_redis_host" /app/moodle/config.php; then
    sed -i -E "s|^\s*\$CFG->session_redis_host\s*=.*|$CFG->session_redis_host = '$REDIS_ENDPOINT';|" /app/moodle/config.php
  else
    sed -i "/require_once.*lib\/setup.php/i \
$CFG->session_handler_class = '\\\\core\\\\session\\\\redis';\
$CFG->session_redis_host = '$REDIS_ENDPOINT';\
$CFG->session_redis_port = 6379;\
$CFG->session_redis_database = 0;\
$CFG->session_redis_serializer_use_igbinary = 0;\
$CFG->session_redis_locking = 1;\
$CFG->session_redis_prefix = 'mdl_sess_';" /app/moodle/config.php
  fi
  php -l /app/moodle/config.php || echo "PHP syntax error in config.php"
  sudo -u apache php /app/moodle/admin/cli/purge_caches.php || true
  systemctl restart php-fpm httpd || true
elif [ "$CONFIG_NEEDS_REBUILD" = "true" ]; then
  echo "Redis endpoint missing for rebuild; skipping config rebuild"
else
  echo "Config already using desired Redis endpoint ($REDIS_ENDPOINT); no rebuild needed"
fi

# Reverse proxy verification and fix
if [ -f "/app/moodle/config.php" ]; then
  LOCAL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health || echo "000")
  ALB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${MOODLE_WWWROOT#*//}" -H "X-Forwarded-Proto: https" http://localhost/ || echo "000")
  if grep -q "reverseproxyabused" /var/log/httpd/error_log 2>/dev/null || [ "$LOCAL_STATUS" != "200" ] || [ "$ALB_STATUS" != "200" ]; then
    if aws s3 cp "s3://$SCRIPT_BUCKET/patch-config-proxy-inplace.sh" /tmp/patch-config-proxy-inplace.sh 2>/dev/null; then
      chmod +x /tmp/patch-config-proxy-inplace.sh || true
      /tmp/patch-config-proxy-inplace.sh || true
    else
      echo "Proxy patch script not found in S3; skipping"
    fi
    systemctl restart php-fpm httpd || true
  fi
  # Force permanent disable of reverse proxy to prevent future issues
  cp /app/moodle/config.php /app/moodle/config.php.backup.final.$(date +%s) || true
  if grep -q "^\s*\$CFG->reverseproxy" /app/moodle/config.php; then
    sed -i -E "s/^\s*\$CFG->reverseproxy\s*=.*/\$CFG->reverseproxy = false;/" /app/moodle/config.php
  else
    sed -i "/require_once.*lib\/setup.php/i \$CFG->reverseproxy = false;" /app/moodle/config.php
  fi
  php -l /app/moodle/config.php || echo "PHP syntax error in config.php"
  sudo -u apache php /app/moodle/admin/cli/purge_caches.php || true
  systemctl restart php-fpm httpd || true
fi

# SES setup (best-effort)
if [ -f "/app/moodle/config.php" ]; then
  aws s3 cp "s3://$SCRIPT_BUCKET/configure-moodle-ses-email.sh" /tmp/configure-moodle-ses-email.sh || true
  [ -s /tmp/configure-moodle-ses-email.sh ] && chmod +x /tmp/configure-moodle-ses-email.sh && /tmp/configure-moodle-ses-email.sh || true
fi

# ============================================================================
# MENUTOPIC PLUGIN PATCHES (idempotent — safe to run on every boot)
# ============================================================================
echo "=== MENUTOPIC PLUGIN PATCHES ==="
MENUTOPIC_LIB="/app/moodle/course/format/menutopic/lib.php"
MENUTOPIC_CONTENT="/app/moodle/course/format/menutopic/classes/output/courseformat/content.php"
if [ -f "$MENUTOPIC_LIB" ]; then
  # Patch 1: Static reentrancy guard to prevent recursive build_course_cache() / OOM
  if ! grep -q 'in_set_sectionnum' "$MENUTOPIC_LIB"; then
    echo "Applying menutopic reentrancy guard (lib.php)..."
    _PATCH="/tmp/fix-menutopic-recursion.php"
    aws s3 cp "s3://$SCRIPT_BUCKET/ops/fix-menutopic-recursion.php" "$_PATCH" 2>/dev/null || true
    if [ -s "$_PATCH" ]; then
      php "$_PATCH" && echo "✓ Menutopic reentrancy guard applied" || echo "⚠ Menutopic lib.php patch failed (non-fatal)"
    else
      echo "⚠ Could not download menutopic patch from S3 — skipping"
    fi
    rm -f "$_PATCH"
  else
    echo "✓ Menutopic reentrancy guard already in place"
  fi
  # Patch 2: content.php private → protected visibility fix (prevents PHP fatal)
  if [ -f "$MENUTOPIC_CONTENT" ]; then
    if grep -q 'private function get_sections_to_display' "$MENUTOPIC_CONTENT"; then
      sed -i 's/private function get_sections_to_display/protected function get_sections_to_display/' "$MENUTOPIC_CONTENT"
      echo "✓ Menutopic content.php: private → protected on get_sections_to_display()"
    else
      echo "✓ Menutopic content.php visibility already correct"
    fi
  fi
  # Patch 3: Deprecation fix — get_section_number() removed in Moodle 4.4+, use get_sectionnum() (MDL-80248).
  _DEPRECATED_COUNT=$(find /app/moodle/course/format/menutopic/ -name '*.php' \
    ! -name '*.bak*' ! -name '*.backup*' \
    | xargs grep -l 'get_section_number' 2>/dev/null | wc -l)
  if [ "$_DEPRECATED_COUNT" -gt 0 ]; then
    echo "Applying deprecated get_section_number → get_sectionnum in $_DEPRECATED_COUNT file(s)..."
    find /app/moodle/course/format/menutopic/ -name '*.php' \
      ! -name '*.bak*' ! -name '*.backup*' \
      | xargs grep -l 'get_section_number' 2>/dev/null \
      | while read _f; do
          sed -i 's/->get_section_number()/->get_sectionnum()/g' "$_f"
          echo "  ✓ Patched: $_f"
        done
  else
    echo "✓ Menutopic: no get_section_number() calls found (already fixed)"
  fi

  # Patch 4: Remove defunct topics/format.js require from format.php.
  # Moodle 4.x removed /course/format/topics/format.js (replaced by AMD modules).
  # menutopic inherited this call and never cleaned it up — it throws a fatal
  # "Attempt to require a JavaScript file that does not exist" on every page load.
  _FORMAT_PHP="/app/moodle/course/format/menutopic/format.php"
  if [ -f "$_FORMAT_PHP" ]; then
    if grep -q "requires->js.*topics/format\.js" "$_FORMAT_PHP"; then
      sed -i "/requires->js.*topics\/format\.js/d" "$_FORMAT_PHP"
      echo "✓ Menutopic format.php: removed defunct topics/format.js require"
    else
      echo "✓ Menutopic format.php: topics/format.js require already absent"
    fi
  fi

  # Patch 5: Remove noisy debugging() calls from the reentrancy guard in lib.php.
  # The guard is correct, but debugging() fires on every course page load (the recursive
  # constructor is an expected code path, not an error). Use exact Python string replacement
  # (perl regex is too greedy across multi-line blocks on shared EFS).
  if grep -q "format_menutopic: set_sectionnum skipped" "$MENUTOPIC_LIB" 2>/dev/null; then
    aws s3 cp s3://moodle-scripts-483382415631-ca-central-1/fix_menutopic_debug.py /tmp/fix_menutopic_debug.py --region ca-central-1 2>/dev/null \
      && python3 /tmp/fix_menutopic_debug.py \
      && rm -f /tmp/fix_menutopic_debug.py \
      && echo "✓ Menutopic lib.php: removed debugging() calls from reentrancy guard" \
      || echo "⚠ Menutopic lib.php: Patch 5 download/apply failed — check S3 access"
  else
    echo "✓ Menutopic lib.php: no debugging() calls to remove"
  fi
else
  echo "Menutopic plugin not found — skipping patches"
fi

# Patch 6: Remove any invalid $CFG->lock_factory override from config.php.
# The lock_factory was set during an earlier incident to work around a cache
# deadlock, but the class name was incorrectly escaped, causing
# "Lock Factory set in $CFG does not exist" on every request.
# Moodle 4.x defaults to \core\lock\db_record_lock_factory automatically —
# no explicit config entry is needed or correct here.
echo "=== PATCH 6: config.php lock_factory cleanup ==="
_CFG=/app/moodle/config.php
if [ -f "$_CFG" ] && grep -q 'lock_factory' "$_CFG" 2>/dev/null; then
  cp "$_CFG" "${_CFG}.bak.lockfix.$(date +%s)" 2>/dev/null || true
  sed -i '/lock_factory/d' "$_CFG"
  php -l "$_CFG" && echo "✓ Removed lock_factory from config.php (syntax OK)" || echo "⚠ config.php syntax error after lock_factory removal!"
else
  echo "✓ config.php: no lock_factory override present (OK)"
fi

# Always restart PHP-FPM after the patch block so OPcache recompiles the
# patched files. opcache.validate_timestamps=0 means file changes on EFS
# are invisible to running workers until the process restarts.
echo "Restarting PHP-FPM to flush OPcache and activate menutopic patches..."
systemctl restart php-fpm && echo "✓ PHP-FPM restarted" || echo "⚠ PHP-FPM restart failed"
echo "=== MENUTOPIC PLUGIN PATCHES DONE ==="

echo "=== FINAL VERIFICATION ==="
systemctl is-active --quiet httpd && echo "httpd active" || echo "httpd NOT active"
systemctl is-active --quiet php-fpm && echo "php-fpm active" || echo "php-fpm NOT active"
sleep 3
FINAL_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health || echo "000")
ALB_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${MOODLE_WWWROOT#*//}" -H "X-Forwarded-Proto: https" http://localhost/ || echo "000")
echo "Health: $FINAL_HEALTH; ALB: $ALB_TEST"

