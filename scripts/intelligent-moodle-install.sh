#!/bin/bash
set -euo pipefail

# Intelligent Moodle Installer - Optimized for idempotency and performance
# Version: 2025-10-18-v2 - Fixed WWWROOT to use custom domain from MOODLE_WWWROOT env var
# Global logging to both file and console
LOG_FILE=${LOG_FILE:-/var/log/moodle-install.log}
exec > >(tee -a "$LOG_FILE") 2>&1

# Trap errors and print context
on_error() {
  echo "[ERROR] Line $1 exited with status $2"
}
trap 'on_error ${LINENO} $?' ERR

START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "=== INTELLIGENT MOODLE INSTALLATION START at $START_TS ==="

# Ensure mountpoints exist early
mkdir -p /app /data
mkdir -p /app/moodle || true

# ============================================================================
# DISTRIBUTED LOCK: Prevent concurrent installer execution on shared EFS
# ============================================================================
LOCK_FILE="/data/.moodle_installer.lock"
LOCK_ACQUIRED=false
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")

acquire_lock() {
  local max_wait=600  # 10 minutes max wait
  local waited=0

  echo "Attempting to acquire installation lock..."

  while [ $waited -lt $max_wait ]; do
    # Try to create lock file atomically using mkdir (atomic on NFS/EFS)
    if mkdir "$LOCK_FILE" 2>/dev/null; then
      echo "$INSTANCE_ID" > "$LOCK_FILE/owner"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_FILE/timestamp"
      LOCK_ACQUIRED=true
      echo "✓ Lock acquired by instance $INSTANCE_ID"
      return 0
    fi

    # Lock exists - check if it's stale (older than 30 minutes)
    if [ -f "$LOCK_FILE/timestamp" ]; then
      local lock_time owner
      lock_time=$(cat "$LOCK_FILE/timestamp" 2>/dev/null || echo "")
      owner=$(cat "$LOCK_FILE/owner" 2>/dev/null || echo "unknown")

      if [ -n "$lock_time" ]; then
        local lock_epoch now_epoch age
        lock_epoch=$(date -d "$lock_time" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        age=$((now_epoch - lock_epoch))

        if [ $age -gt 1800 ]; then
          echo "Lock is stale (${age}s old, owner: $owner). Removing..."
          rm -rf "$LOCK_FILE" || true
          continue
        fi

        echo "Lock held by instance $owner (age: ${age}s). Waiting..."
      fi
    fi

    sleep 10
    waited=$((waited + 10))
  done

  echo "ERROR: Could not acquire lock after ${max_wait}s. Another instance may be installing."
  exit 1
}

release_lock() {
  if [ "$LOCK_ACQUIRED" = true ]; then
    echo "Releasing installation lock..."
    rm -rf "$LOCK_FILE" || true
    LOCK_ACQUIRED=false
  fi
}

# Ensure lock is released on exit
trap release_lock EXIT

# Acquire the lock before proceeding
acquire_lock

cd /app/moodle

# Get parameters from environment or discover dynamically
REGION=${REGION:-$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo 'ca-central-1')}
if [ -z "$REGION" ]; then REGION='ca-central-1'; fi

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
STACK_NAME=$(aws ec2 describe-tags --region "$REGION" --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:cloudformation:stack-name" --query "Tags[0].Value" --output text 2>/dev/null || echo 'MoodleCdkStack')

echo "Region: $REGION, Stack: $STACK_NAME"

# --- Automatic, idempotent EFS mounting using dynamic discovery ---
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

discover_efs_ids() {
  if [ -z "${APP_EFS_ID:-}" ] || [ -z "${DATA_EFS_ID:-}" ]; then
    local app_out data_out
    app_out=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='AppEfsId'].OutputValue" --output text 2>/dev/null || echo "")
    data_out=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='DataEfsId'].OutputValue" --output text 2>/dev/null || echo "")
    if [ -z "${APP_EFS_ID:-}" ] && [ -n "$app_out" ] && [ "$app_out" != "None" ]; then APP_EFS_ID="$app_out"; fi
    if [ -z "${DATA_EFS_ID:-}" ] && [ -n "$data_out" ] && [ "$data_out" != "None" ]; then DATA_EFS_ID="$data_out"; fi
  fi
  log "EFS IDs -> APP: ${APP_EFS_ID:-unset} DATA: ${DATA_EFS_ID:-unset}"
}

add_fstab_entry() {
  # $1 = EFS_ID, $2 = mountpoint
  local efs_id="$1" mnt="$2"
  if command -v mount.efs >/dev/null 2>&1; then
    grep -qE "^${efs_id}\.efs\.${REGION}\.amazonaws\.com:/\s+${mnt//\//\\/}\s+efs" /etc/fstab || \
      echo "${efs_id}.efs.${REGION}.amazonaws.com:/ ${mnt} efs _netdev,tls,iam 0 0" >> /etc/fstab
  else
    grep -qE "^${efs_id}\.efs\.${REGION}\.amazonaws\.com:/\s+${mnt//\//\\/}\s+nfs4" /etc/fstab || \
      echo "${efs_id}.efs.${REGION}.amazonaws.com:/ ${mnt} nfs4 nfsvers=4.1,noresvport,_netdev 0 0" >> /etc/fstab
  fi
}

try_mount_dns() {
  # $1 = EFS_ID, $2 = mountpoint
  local efs_id="$1" mnt="$2"
  if command -v mount.efs >/dev/null 2>&1; then
    mount -t efs -o tls,iam "${efs_id}:/" "$mnt"
  else
    mount -t nfs4 -o nfsvers=4.1,noresvport "${efs_id}.efs.${REGION}.amazonaws.com:/" "$mnt"
  fi
}

try_mount_ip() {
  # $1 = EFS_ID, $2 = mountpoint
  local efs_id="$1" mnt="$2"
  local token az macs mac subnet_id ip iface src_ip
  token=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds:60 || true)
  az=$(curl -sS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone || true)
  # Determine default-route interface and source IP
  iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  src_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/ src / {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  # Map source IP to IMDS MAC to obtain the exact subnet-id
  macs=$(curl -sS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/network/interfaces/macs/ 2>/dev/null | tr -d '/\r' | tr '\n' ' ')
  for m in $macs; do
    local ips
    ips=$(curl -sS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${m}/local-ipv4s" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    for ipi in $ips; do
      if [ "$ipi" = "$src_ip" ]; then mac="$m"; break; fi
    done
    [ -n "$mac" ] && break
  done
  if [ -n "$mac" ]; then
    subnet_id=$(curl -sS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}/subnet-id" 2>/dev/null || true)
  fi
  # Prefer mount target in the same subnet; else same AZ; else first available
  if [ -n "$subnet_id" ]; then
    ip=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$efs_id" --query "MountTargets[?SubnetId=='${subnet_id}'].IpAddress" --output text 2>/dev/null || echo "")
  fi
  if [ -z "$ip" ] || [ "$ip" = "None" ]; then
    ip=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$efs_id" --query "MountTargets[?AvailabilityZoneName=='${az}'].IpAddress" --output text 2>/dev/null || echo "")
  fi
  if [ -z "$ip" ] || [ "$ip" = "None" ]; then
    ip=$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$efs_id" --query "MountTargets[0].IpAddress" --output text 2>/dev/null || echo "")
  fi
  if [ -n "$ip" ] && [ "$ip" != "None" ]; then
    # Note: mounting by raw IP uses NFSv4 without TLS; will be denied if EFS enforces encryption-in-transit
    mount -t nfs4 -o nfsvers=4.1,noresvport "${ip}:/" "$mnt"
  else
    return 1
  fi
}

efs_mount_one() {
  # $1 = label, $2 = EFS_ID, $3 = mountpoint
  local label="$1" efs_id="$2" mnt="$3"
  mkdir -p "$mnt"
  if mountpoint -q "$mnt"; then log "$label: already mounted at $mnt"; return 0; fi
  log "$label: mounting $efs_id at $mnt (REGION=$REGION)"
  # DNS retries (10 minutes total)
  local i
  for i in $(seq 1 60); do
    if mountpoint -q "$mnt"; then break; fi
    if try_mount_dns "$efs_id" "$mnt" 2>/dev/null; then break; fi
    sleep 10
  done
  if ! mountpoint -q "$mnt"; then
    log "$label: DNS mount failed, trying IP fallback"
    try_mount_ip "$efs_id" "$mnt" 2>/dev/null || true
  fi
  if mountpoint -q "$mnt"; then
    add_fstab_entry "$efs_id" "$mnt"
    log "✓ $label EFS mounted on $mnt"
    return 0
  else
    log "✗ $label EFS mount failed for $efs_id at $mnt"
    return 1
  fi
}

mount_efs() {
  discover_efs_ids
  if [ -n "${APP_EFS_ID:-}" ]; then efs_mount_one APP "$APP_EFS_ID" /app || true; else log "APP_EFS_ID not set"; fi
  if [ -n "${DATA_EFS_ID:-}" ]; then efs_mount_one DATA "$DATA_EFS_ID" /data || true; else log "DATA_EFS_ID not set"; fi
  log "Mounted filesystems:"; mount | egrep "type nfs4|efs\." || true
  df -h /app /data || true
}

# Perform EFS mounts early so subsequent steps operate on the shared volumes
mount_efs


# Dynamic discovery of database credentials with multiple fallback methods
DB_USER=""
DB_PASS=""
DB_NAME="moodle"

# Method 1: Use provided secret ARN from CDK
if [ -n "${DB_SECRET_ARN:-}" ] && [ "$DB_SECRET_ARN" != "None" ]; then
  echo "Method 1: Using provided secret ARN..."
  DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region "$REGION" --query SecretString --output text 2>/dev/null || echo "")
  if [ -n "$DB_CREDS" ]; then
    DB_USER=$(echo "$DB_CREDS" | jq -r .username 2>/dev/null || echo "")
    DB_PASS=$(echo "$DB_CREDS" | jq -r .password 2>/dev/null || echo "")
    DB_NAME=$(echo "$DB_CREDS" | jq -r .dbname 2>/dev/null || echo "moodle")
    echo "Successfully retrieved credentials from provided secret"
  fi
fi

# Method 2: Discover secret by name pattern if Method 1 failed
if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  echo "Method 2: Discovering secret by name pattern..."
  DISCOVERED_SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" --query "SecretList[?contains(Name, \`Moodle\`) || contains(Name, \`Db\`) || contains(Name, \`DB\`)].ARN" --output text 2>/dev/null | head -1 || echo "")
  if [ -n "$DISCOVERED_SECRET_ARN" ]; then
    echo "Found secret: $DISCOVERED_SECRET_ARN"
    DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DISCOVERED_SECRET_ARN" --region "$REGION" --query SecretString --output text 2>/dev/null || echo "")
    if [ -n "$DB_CREDS" ]; then
      DB_USER=$(echo "$DB_CREDS" | jq -r .username 2>/dev/null || echo "")
      DB_PASS=$(echo "$DB_CREDS" | jq -r .password 2>/dev/null || echo "")
      DB_NAME=$(echo "$DB_CREDS" | jq -r .dbname 2>/dev/null || echo "moodle")
      echo "Successfully retrieved credentials from discovered secret"
    fi
  fi
fi

# Method 3: Use first available secret as last resort
if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  echo "Method 3: Using first available secret..."
  FIRST_SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" --query "SecretList[0].ARN" --output text 2>/dev/null || echo "")
  if [ -n "$FIRST_SECRET_ARN" ] && [ "$FIRST_SECRET_ARN" != "None" ]; then
    echo "Trying first secret: $FIRST_SECRET_ARN"
    DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$FIRST_SECRET_ARN" --region "$REGION" --query SecretString --output text 2>/dev/null || echo "")
    if [ -n "$DB_CREDS" ]; then
      DB_USER=$(echo "$DB_CREDS" | jq -r .username 2>/dev/null || echo "")
      DB_PASS=$(echo "$DB_CREDS" | jq -r .password 2>/dev/null || echo "")
      DB_NAME=$(echo "$DB_CREDS" | jq -r .dbname 2>/dev/null || echo "moodle")
      echo "Successfully retrieved credentials from first available secret"
    fi
  fi
fi

# Validate credentials
if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
  echo "ERROR: Could not retrieve database credentials from any method!"
  echo "DB_SECRET_ARN: ${DB_SECRET_ARN:-}"
  echo "Available secrets:"
  aws secretsmanager list-secrets --region "$REGION" --query "SecretList[*].Name" --output text 2>/dev/null || echo "Could not list secrets"
  exit 1
fi

echo "Database credentials retrieved successfully"
echo "DB_USER: $DB_USER, DB_NAME: $DB_NAME"

# Discover database endpoint
if [ -z "${DB_ENDPOINT:-}" ]; then
  DB_ENDPOINT=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabaseEndpoint'].OutputValue" --output text 2>/dev/null || echo "")
fi
if [ -z "$DB_ENDPOINT" ] || [ "$DB_ENDPOINT" = "None" ]; then
  echo "Discovering DB endpoint from RDS..."
  DB_ENDPOINT=$(aws rds describe-db-instances --region "$REGION" --query "DBInstances[0].Endpoint.Address" --output text 2>/dev/null || echo "")
fi

# Discover Moodle URL with multiple fallback methods
# Priority: Environment variable > CloudFormation > ALB discovery > Instance hostname
WWWROOT=""

# Method 0: Use environment variable if provided (highest priority - from CDK)
if [ -n "${MOODLE_WWWROOT:-}" ]; then
  WWWROOT="$MOODLE_WWWROOT"
  echo "✓ Using MOODLE_WWWROOT from environment: $WWWROOT"
fi

if [ -z "$WWWROOT" ]; then
  echo "Method 1: CloudFormation outputs..."
  ALB_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='MoodleUrl'].OutputValue" --output text 2>/dev/null || echo "")
  if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
    WWWROOT="$ALB_URL"
    echo "Found ALB URL from CloudFormation: $WWWROOT"
  fi
fi

if [ -z "$WWWROOT" ]; then
  echo "Method 2: ALB discovery by name pattern..."
  ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?contains(LoadBalancerName, \`Moodle\`) || contains(LoadBalancerName, \`moodle\`)].DNSName" --output text 2>/dev/null | head -1 || echo "")
  if [ -n "$ALB_DNS_NAME" ]; then
    WWWROOT="http://$ALB_DNS_NAME"
    echo "Found ALB URL by name pattern: $WWWROOT"
  fi
fi

if [ -z "$WWWROOT" ]; then
  echo "Method 3: First available ALB..."
  ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[0].DNSName" --output text 2>/dev/null || echo "")
  if [ -n "$ALB_DNS_NAME" ] && [ "$ALB_DNS_NAME" != "None" ]; then
    WWWROOT="http://$ALB_DNS_NAME"
    echo "Found ALB URL from first available: $WWWROOT"
  fi
fi

if [ -z "$WWWROOT" ]; then
  echo "Method 4: Instance public hostname fallback..."
  PUBLIC_HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname 2>/dev/null || echo "")
  if [ -n "$PUBLIC_HOSTNAME" ]; then
    WWWROOT="http://$PUBLIC_HOSTNAME"
    echo "Using instance public hostname: $WWWROOT"
  else
    echo "Warning: Could not determine any URL, using localhost"
    WWWROOT="http://localhost"
  fi
fi

  # Idempotent protocol detection: prefer HTTPS when ALB exposes 443
  if [ -n "$WWWROOT" ]; then
    CANDIDATE_HTTPS="${WWWROOT/http:\/\//https://}"
    # Try https health quickly (skip cert validation because ALB terminates TLS)
    if curl -sk --max-time 5 "$CANDIDATE_HTTPS/health" | grep -q "OK"; then
      echo "HTTPS health OK; switching WWWROOT to $CANDIDATE_HTTPS"
      WWWROOT="$CANDIDATE_HTTPS"
    else
      # Fallback: check if ALB has a 443 listener via SSM parameter with ALB ARN
      ALB_ARN=$(aws ssm get-parameter --name "/moodle/albArn" --region "$REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "")
      if [ -n "$ALB_ARN" ]; then
        if aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$ALB_ARN" --query "Listeners[?Port==\`443\`].ListenerArn" --output text 2>/dev/null | grep -q .; then
          echo "Detected HTTPS listener on ALB; switching WWWROOT to $CANDIDATE_HTTPS"
          WWWROOT="$CANDIDATE_HTTPS"
        fi
      fi
    fi
  fi


# Insert/refresh Moodle proxy flags before require_once in config.php
# FIXED 2025-10-18: Removed reverseproxy=true to prevent "Reverse proxy enabled" error
# For ALB with SSL termination, only sslproxy=true is needed
set_proxy_flags_in_config() {
  local proto="$1"
  local cfg="/app/moodle/config.php"
  [ -f "$cfg" ] || return 0
  # Remove any existing proxy settings to ensure clean state
  sed -i "/^\$CFG->reverseproxy/d; /^\$CFG->sslproxy/d; /^\$CFG->cookiesecure/d; /^\$CFG->loginhttps/d; /^\$CFG->getremoteaddrconf/d" "$cfg" || true

  # For HTTPS with ALB SSL termination:
  # - sslproxy=true tells Moodle to trust X-Forwarded-Proto header from ALB
  # - reverseproxy should NOT be set (setting it to true blocks direct access from ALB)
  # - This prevents the "Reverse proxy enabled so the server cannot be accessed directly" error
  # - This also prevents redirect loops (ERR_TOO_MANY_REDIRECTS)
  if [ "$proto" = "https" ]; then
    sed -i "/require_once.*lib\/setup\.php/i \\\$CFG->sslproxy = true;" "$cfg"
    echo "✓ Set sslproxy=true for HTTPS ALB SSL termination"
  fi
  # Note: reverseproxy, getremoteaddrconf, cookiesecure, loginhttps are intentionally NOT set
  # to avoid blocking direct access from the ALB
}


echo "=== ANALYZING INSTALLATION STATE ==="
CONFIG_EXISTS=false
DB_INITIALIZED=false
DB_ACCESSIBLE=false
TABLES_COMPLETE=false
STATE_MARKER=/data/.moodle_install_state
if [ -f "$STATE_MARKER" ]; then
  echo "Found previous state marker:"; cat "$STATE_MARKER" || true
fi

# Check if config.php exists
if [ -f "/app/moodle/config.php" ]; then
  CONFIG_EXISTS=true
  echo "✓ Config.php exists"
else
  echo "✗ Config.php does not exist"
fi

# Test database connectivity
if mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" 2>/dev/null; then
  DB_ACCESSIBLE=true
  echo "✓ Database is accessible"

  # Check if database exists and has tables
  if mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SELECT 1;" 2>/dev/null; then
    echo "✓ Database exists"

    # Check if core Moodle tables exist
    TABLE_COUNT=$(mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SHOW TABLES LIKE \"mdl_%\";" 2>/dev/null | wc -l || echo "0")
    echo "Found $TABLE_COUNT Moodle tables"

    if [ "$TABLE_COUNT" -gt 50 ]; then
      TABLES_COMPLETE=true
      echo "✓ Moodle tables appear complete"

      # Check if installation is properly initialized
      VERSION_CHECK=$(mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT COUNT(*) FROM mdl_config WHERE name=\"version\";" 2>/dev/null | tail -1 || echo "0")
      if [ "$VERSION_CHECK" -gt 0 ]; then
        DB_INITIALIZED=true
        echo "✓ Database appears properly initialized"
      else
        echo "✗ Database tables exist but not properly initialized"
      fi
    else
      echo "✗ Moodle tables incomplete or missing"
    fi
  else
    echo "ℹ Database does not exist, will be created"
  fi
else
  echo "✗ Database is not accessible"
fi

# Determine installation strategy based on analysis
echo "=== DETERMINING INSTALLATION STRATEGY ==="
STRATEGY="unknown"

if [ "$CONFIG_EXISTS" = false ] && [ "$DB_INITIALIZED" = false ]; then
  STRATEGY="fresh_install"
  echo "Strategy: Fresh installation (no config, no database)"
elif [ "$CONFIG_EXISTS" = true ] && [ "$DB_INITIALIZED" = false ]; then
  STRATEGY="repair_install"
  echo "Strategy: Repair installation (config exists but database incomplete)"
elif [ "$CONFIG_EXISTS" = false ] && [ "$DB_INITIALIZED" = true ]; then
  STRATEGY="recreate_config"
  echo "Strategy: Recreate config (database exists but no config)"
elif [ "$CONFIG_EXISTS" = true ] && [ "$DB_INITIALIZED" = true ]; then
  STRATEGY="update_existing"
  echo "Strategy: Update existing installation (both config and database exist)"
else
  STRATEGY="force_repair"
  echo "Strategy: Force repair (unclear state, will attempt to fix)"
fi

# Ensure Moodle code is available (idempotent)
echo "=== ENSURING MOODLE CODE AVAILABILITY ==="
if [ ! -f "/app/moodle/index.php" ]; then
  echo "Downloading Moodle using official Git method..."
  cd /app
  if [ -d "/app/moodle/.git" ]; then
    echo "Repo exists; fetching updates..."
    cd /app/moodle
    git fetch --all --prune || true
    git checkout MOODLE_500_STABLE || true
    git reset --hard origin/MOODLE_500_STABLE || true
  else
    rm -rf moodle 2>/dev/null || true
    git clone https://github.com/moodle/moodle.git
    cd moodle
    git branch --track MOODLE_500_STABLE origin/MOODLE_500_STABLE || true
    git checkout MOODLE_500_STABLE || true
  fi
  # Only chown if needed (check a sample file)
  if [ -f "/app/moodle/index.php" ]; then
    current_owner=$(stat -c '%U' /app/moodle/index.php 2>/dev/null || echo "")
    if [ "$current_owner" != "apache" ]; then
      echo "Fixing ownership of /app/moodle (current owner: $current_owner)..."
      chown -R apache:apache /app/moodle
    else
      echo "Ownership already correct for /app/moodle"
    fi
  fi
  echo "✓ Moodle code ready"
else
  echo "✓ Moodle code already available"
fi

# Ensure proper permissions before installation
# Increase PHP limits required by Moodle before running CLI install
PHP_INI_ADD=/etc/php.d/99-moodle.ini
cat > "$PHP_INI_ADD" <<'PHPINI'
max_input_vars = 5000
post_max_size = 1024M
upload_max_filesize = 1024M
max_execution_time = 600
max_input_time = 900
memory_limit = 4096M
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0
opcache.save_comments = 1
PHPINI
systemctl restart php-fpm || true
systemctl restart httpd || true

mkdir -p /data/moodledata

# Only chown if ownership is incorrect (idempotent check)
echo "Checking ownership of /app/moodle and /data/moodledata..."
NEEDS_CHOWN=false
if [ -f "/app/moodle/index.php" ]; then
  APP_OWNER=$(stat -c '%U' /app/moodle/index.php 2>/dev/null || echo "")
  if [ "$APP_OWNER" != "apache" ]; then
    echo "  /app/moodle needs ownership fix (current: $APP_OWNER)"
    NEEDS_CHOWN=true
  fi
fi
if [ -d "/data/moodledata" ]; then
  DATA_OWNER=$(stat -c '%U' /data/moodledata 2>/dev/null || echo "")
  if [ "$DATA_OWNER" != "apache" ]; then
    echo "  /data/moodledata needs ownership fix (current: $DATA_OWNER)"
    NEEDS_CHOWN=true
  fi
fi

if [ "$NEEDS_CHOWN" = true ]; then
  echo "Fixing ownership (this may take a few minutes on large installations)..."
  chown -R apache:apache /app/moodle /data/moodledata
  echo "✓ Ownership fixed"

  # Only set permissions if we just fixed ownership (likely first run)
  echo "Setting basic permissions after ownership fix..."
  chmod -R 755 /app/moodle 2>/dev/null || true
  chmod -R 777 /data/moodledata 2>/dev/null || true
  echo "✓ Basic permissions set"
else
  echo "✓ Ownership already correct, skipping chown and chmod"
fi

# Make mounts idempotent if script is run directly (guards)
if ! mountpoint -q /app && [ -n "${APP_EFS_ID:-}" ]; then
  echo "Mounting /app via script guard..."
  mount -t nfs4 -o nfsvers=4.1 "$APP_EFS_ID.efs.$REGION.amazonaws.com:/" /app || true
fi
if ! mountpoint -q /data && [ -n "${DATA_EFS_ID:-}" ]; then
  echo "Mounting /data via script guard..."
  mount -t nfs4 -o nfsvers=4.1 "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/" /data || true
fi

# Execute installation strategy
echo "=== EXECUTING INSTALLATION STRATEGY: $STRATEGY ==="
case "$STRATEGY" in
  "fresh_install")
    echo "Performing fresh CLI installation..."
    sudo -u apache php admin/cli/install.php \
      --lang=en \
      --wwwroot="$WWWROOT" \
      --dataroot="/data/moodledata" \
      --dbtype=mariadb \
      --dbhost="$DB_ENDPOINT" \
      --dbname="$DB_NAME" \
      --dbuser="$DB_USER" \
      --dbpass="$DB_PASS" \
      --dbport=3306 \
      --prefix=mdl_ \
      --fullname="${MOODLE_SITE_NAME:-Touchstone Institute}" \
      --shortname="TSI" \
      --adminuser="${MOODLE_ADMIN_USER:-moodle-admin}" \
      --adminpass="TempPass123!" \
      --adminemail="${MOODLE_ADMIN_EMAIL:-it@tsin.ca}" \
      --non-interactive \
      --agree-license && echo "✓ Fresh installation completed" || echo "✗ Fresh installation failed"
    # Ensure reverse proxy/cookie settings to avoid redirect loops behind ALB
    PROTO=$(echo "$WWWROOT" | cut -d: -f1)
    set_proxy_flags_in_config "$PROTO"
    ;;
  "repair_install"|"force_repair")
    echo "Repairing installation - dropping existing tables and reinstalling..."
    # Drop all existing Moodle tables safely
    mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SET FOREIGN_KEY_CHECKS = 0;" 2>/dev/null || true
    TABLES_TO_DROP=$(mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SHOW TABLES LIKE \"mdl_%\";" 2>/dev/null | grep mdl_ | tr "\n" " " || echo "")
    if [ -n "$TABLES_TO_DROP" ]; then
      for table in $TABLES_TO_DROP; do
        mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "DROP TABLE IF EXISTS $table;" 2>/dev/null || true
      done
      echo "✓ Dropped existing Moodle tables"
    fi
    mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SET FOREIGN_KEY_CHECKS = 1;" 2>/dev/null || true
    # Remove config and reinstall
    rm -f /app/moodle/config.php
    sudo -u apache php admin/cli/install.php \
      --lang=en \
      --wwwroot="$WWWROOT" \
      --dataroot="/data/moodledata" \
      --dbtype=mariadb \
      --dbhost="$DB_ENDPOINT" \
      --dbname="$DB_NAME" \
      --dbuser="$DB_USER" \
      --dbpass="$DB_PASS" \
      --dbport=3306 \
      --prefix=mdl_ \
      --fullname="${MOODLE_SITE_NAME:-Touchstone Institute}" \
      --shortname="TSI" \
      --adminuser="${MOODLE_ADMIN_USER:-moodle-admin}" \
      --adminpass="TempPass123!" \
      --adminemail="${MOODLE_ADMIN_EMAIL:-it@tsin.ca}" \
      --non-interactive \
      --agree-license && echo "✓ Repair installation completed" || echo "✗ Repair installation failed"
    ;;
  "recreate_config")
    echo "Recreating config.php for existing database..."
    cat > /app/moodle/config.php << "RECREATE_CONFIG_EOF"
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype    = "mariadb";
$CFG->dblibrary = "native";
RECREATE_CONFIG_EOF
    echo "\$CFG->dbhost    = '$DB_ENDPOINT';" >> /app/moodle/config.php
    echo "\$CFG->dbname    = '$DB_NAME';" >> /app/moodle/config.php
    # Ensure debug flags present as requested (before require_once)
    sed -i "/require_once.*lib\/setup\.php/i \\\$CFG->debugdisplay = 1;" /app/moodle/config.php
    sed -i "/require_once.*lib\/setup\.php/i \\\$CFG->debug = (E_ALL | E_STRICT);" /app/moodle/config.php

    echo "\$CFG->dbuser    = '$DB_USER';" >> /app/moodle/config.php
    echo "\$CFG->dbpass    = '$DB_PASS';" >> /app/moodle/config.php
    echo "\$CFG->wwwroot   = '$WWWROOT';" >> /app/moodle/config.php
    cat >> /app/moodle/config.php << "RECREATE_CONFIG_EOF2"
$CFG->prefix    = "mdl_";
$CFG->dboptions = array (
  "dbpersist" => 0,
  "dbport" => 3306,
  "dbsocket" => "",
  "dbcollation" => "utf8mb4_unicode_ci",
);
$CFG->dataroot  = "/data/moodledata";
$CFG->admin     = "admin";
$CFG->directorypermissions = 0777;
require_once(__DIR__ . "/lib/setup.php");
RECREATE_CONFIG_EOF2
    chown apache:apache /app/moodle/config.php
    chmod 644 /app/moodle/config.php
    echo "✓ Config recreated for existing database"
    ;;
  "update_existing")
    echo "Updating existing installation..."
    echo "Config.php and database already exist - skipping modifications to preserve working configuration"
    # Only verify config.php syntax
    if php -l /app/moodle/config.php >/dev/null 2>&1; then
      echo "✓ Config.php syntax is valid"
    else
      echo "⚠ Config.php has syntax errors - will not modify"
    fi
    # Run upgrade to ensure everything is current (safe operation)
    cd /app/moodle
    sudo -u apache php admin/cli/upgrade.php --non-interactive 2>&1 | head -n 20 && echo "✓ Upgrade check completed" || echo "⚠ Upgrade check failed or not needed"
    echo "✓ Existing installation verified (no changes made)"
    ;;

  *)
    echo "⚠ Unknown strategy: $STRATEGY, enabling manual browser installation..."
    # Create basic config.php for manual browser-based installation
    echo "Creating config.php for manual installation via web browser..."
    cat > /app/moodle/config.php << "MANUAL_INSTALL_CONFIG_EOF"
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = "mariadb";
$CFG->dblibrary = "native";
MANUAL_INSTALL_CONFIG_EOF
    echo "\$CFG->dbhost    = '$DB_ENDPOINT';" >> /app/moodle/config.php
    echo "\$CFG->dbname    = '$DB_NAME';" >> /app/moodle/config.php
    echo "\$CFG->dbuser    = '$DB_USER';" >> /app/moodle/config.php
    echo "\$CFG->dbpass    = '$DB_PASS';" >> /app/moodle/config.php
    echo "\$CFG->wwwroot   = '$WWWROOT';" >> /app/moodle/config.php
    cat >> /app/moodle/config.php << "MANUAL_INSTALL_CONFIG_EOF2"
$CFG->prefix    = "mdl_";
$CFG->dboptions = array (
  "dbpersist" => 0,
  "dbport" => 3306,
  "dbsocket" => "",
  "dbcollation" => "utf8mb4_unicode_ci",
);
$CFG->dataroot  = "/data/moodledata";
$CFG->admin     = "admin";
$CFG->directorypermissions = 0777;

// Uncomment the following line after completing the web-based installation
// require_once(__DIR__ . "/lib/setup.php");
MANUAL_INSTALL_CONFIG_EOF2
    chown apache:apache /app/moodle/config.php
    chmod 644 /app/moodle/config.php
    echo "✓ Config created for manual installation"
    echo "ℹ Visit $WWWROOT to complete installation via web browser"
    echo "ℹ After web installation, uncomment the require_once line in config.php"
    ;;
esac

# Strategy execution completed, now handle any failures with config creation
if [ ! -f "/app/moodle/config.php" ]; then
  echo "⚠ No config.php found after strategy execution, enabling manual browser installation..."
  cat > /app/moodle/config.php << "FALLBACK_CONFIG_EOF"
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = "mariadb";
$CFG->dblibrary = "native";
FALLBACK_CONFIG_EOF
  echo "\$CFG->dbhost    = '$DB_ENDPOINT';" >> /app/moodle/config.php
  echo "\$CFG->dbname    = '$DB_NAME';" >> /app/moodle/config.php
  echo "\$CFG->dbuser    = '$DB_USER';" >> /app/moodle/config.php
  echo "\$CFG->dbpass    = '$DB_PASS';" >> /app/moodle/config.php
  echo "\$CFG->wwwroot   = '$WWWROOT';" >> /app/moodle/config.php
  cat >> /app/moodle/config.php << "FALLBACK_CONFIG_EOF2"
$CFG->prefix    = "mdl_";
$CFG->dboptions = array (
  "dbpersist" => 0,
  "dbport" => 3306,
  "dbsocket" => "",
  "dbcollation" => "utf8mb4_unicode_ci",
);
$CFG->dataroot  = "/data/moodledata";
$CFG->admin     = "admin";
$CFG->directorypermissions = 0777;

// Uncomment the following line after completing the web-based installation
// require_once(__DIR__ . "/lib/setup.php");
FALLBACK_CONFIG_EOF2
  chown apache:apache /app/moodle/config.php
  chmod 644 /app/moodle/config.php
  echo "✓ Fallback config created for manual browser installation"
  echo "ℹ Visit $WWWROOT to complete installation via web browser"
  echo "ℹ After web installation, uncomment the require_once line in config.php"
else
  echo "✓ Config.php exists after strategy execution"
fi

# Clear caches after installation
echo "Clearing Moodle caches..."
rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/* /data/moodledata/temp/* 2>/dev/null || echo "Caches cleared"

# Update database wwwroot if config exists and database is accessible
if [ -f "/app/moodle/config.php" ] && mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT 1;" 2>/dev/null; then
  mariadb -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "UPDATE mdl_config SET value=\"$WWWROOT\" WHERE name=\"wwwroot\";" 2>/dev/null && echo "✓ Database wwwroot synchronized" || echo "ℹ Database wwwroot sync not needed"
fi

# ============================================================================
# MENUTOPIC PLUGIN PATCHES (idempotent — safe to run on every boot)
# Ensures fixes survive fresh installs, plugin upgrades, and EFS replacement.
# ============================================================================
echo "=== MENUTOPIC PLUGIN PATCHES ==="
MENUTOPIC_LIB="/app/moodle/course/format/menutopic/lib.php"
MENUTOPIC_CONTENT="/app/moodle/course/format/menutopic/classes/output/courseformat/content.php"

# Derive script bucket if not already exported by caller (bootstrap-moodle.sh sets it)
if [ -z "${SCRIPT_BUCKET:-}" ]; then
  _ACCT=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .accountId 2>/dev/null || \
          aws sts get-caller-identity --region "$REGION" --query Account --output text 2>/dev/null || echo "")
  SCRIPT_BUCKET="moodle-scripts-${_ACCT}-${REGION}"
fi

if [ -f "$MENUTOPIC_LIB" ]; then
  # Patch 1: Static reentrancy guard — prevents recursive build_course_cache()
  # deadlock that causes 10+ second hangs and eventual OOM at url.php:207.
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

  # Patch 2: Visibility fix — content.php declares get_sections_to_display() as
  # private but Moodle core requires protected (or weaker). Fatal if wrong.
  if [ -f "$MENUTOPIC_CONTENT" ]; then
    if grep -q 'private function get_sections_to_display' "$MENUTOPIC_CONTENT"; then
      sed -i 's/private function get_sections_to_display/protected function get_sections_to_display/' "$MENUTOPIC_CONTENT"
      echo "✓ Menutopic content.php: private → protected on get_sections_to_display()"
    else
      echo "✓ Menutopic content.php visibility already correct"
    fi
  fi

  # Patch 3: Deprecation fix — get_section_number() removed in Moodle 4.4+, use get_sectionnum().
  # Affects edition.php, content.php, and content/section.php (MDL-80248).
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
  echo "Menutopic plugin not found — skipping patches (plugin may not be installed yet)"
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

echo "=== INTELLIGENT INSTALLATION COMPLETE ==="
echo "Strategy used: $STRATEGY"
echo "Moodle should be accessible at: $WWWROOT"
echo "Admin credentials: ${MOODLE_ADMIN_USER:-moodle-admin} / TempPass123!"

# Final setup and service management
echo "=== FINAL SETUP ==="

# Only run expensive operations if needed
FINAL_OWNER_APP=$(stat -c '%U' /app/moodle 2>/dev/null || echo "")
FINAL_OWNER_DATA=$(stat -c '%U' /data/moodledata 2>/dev/null || echo "")

if [ "$FINAL_OWNER_APP" != "apache" ] || [ "$FINAL_OWNER_DATA" != "apache" ]; then
  echo "Final ownership fix required..."
  chown -R apache:apache /app/moodle /data/moodledata
  echo "✓ Final ownership set"
else
  echo "✓ Ownership already correct, skipping final chown"
fi

# Only run find/chmod if this is a fresh install AND we haven't already set permissions
# Skip if:
# - update_existing strategy (app already installed and working)
# - NEEDS_CHOWN was true (we already ran chmod -R in lines 513-514)
if [ "$NEEDS_CHOWN" = true ]; then
  echo "✓ Permissions already set during ownership fix (skipping expensive find commands)"
elif [ "$STRATEGY" = "fresh_install" ] || [ "$STRATEGY" = "repair_install" ] || [ "$STRATEGY" = "recreate_config" ] || [ "$STRATEGY" = "force_repair" ]; then
  echo "Setting granular file permissions (strategy: $STRATEGY - this will take several minutes)..."
  find /app/moodle -type f -exec chmod 644 {} \; 2>/dev/null || true
  find /app/moodle -type d -exec chmod 755 {} \; 2>/dev/null || true
  chmod -R 777 /data/moodledata 2>/dev/null || true
  echo "✓ Granular permissions set"
else
  echo "✓ Skipping permission reset (strategy: $STRATEGY - app already installed)"
fi

# Write state marker
(
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "strategy=$STRATEGY"
  echo "wwwroot=$WWWROOT"
  echo "db_endpoint=$DB_ENDPOINT"
) > "$STATE_MARKER"

# Create health check endpoints for ALB
echo "Creating health check endpoints..."

# Create PHP health endpoint
cat > /app/moodle/health.php << 'EOF'
<?php
// Simple health check for ALB
http_response_code(200);
echo "OK";
?>
EOF
chown apache:apache /app/moodle/health.php
chmod 644 /app/moodle/health.php

# Create simple text health endpoint (more reliable)
echo "OK" > /app/moodle/health
chown apache:apache /app/moodle/health
chmod 644 /app/moodle/health

echo "✓ Health check endpoints created (both /health.php and /health)"

echo "✓ Intelligent Moodle installation script completed successfully!"
