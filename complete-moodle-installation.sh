#!/bin/bash
set -e  # Exit on any error

echo "=== Complete Moodle Installation Script ==="
echo "Starting at: $(date)"

# Get current instance information
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
STACK_NAME="MoodleCdkStack"

echo "Region: $REGION"
echo "Instance ID: $INSTANCE_ID"
echo "Stack name: $STACK_NAME"

# Step 1: Install missing packages
echo "=== Step 1: Installing required packages ==="
dnf install -y httpd php php-fpm php-cli php-common php-curl php-gd php-intl php-ldap php-mbstring php-mysqli php-opcache php-pdo php-soap php-xml php-zip php-sodium php-json php-devel mariadb105 git unzip jq amazon-efs-utils amazon-cloudwatch-agent awscli nfs-utils

# Step 2: Get database credentials
echo "=== Step 2: Getting database credentials ==="
DB_SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" --query "SecretList[?contains(Name, 'MoodleDbSecret')].ARN" --output text | head -1)
echo "Database secret ARN: $DB_SECRET_ARN"

DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region "$REGION" --query SecretString --output text)
DB_USER=$(echo "$DB_CREDS" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS" | jq -r .password)
DB_ENDPOINT=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='DatabaseEndpoint'].OutputValue" --output text)

echo "Database endpoint: $DB_ENDPOINT"
echo "Database user: $DB_USER"

# Test database connection
echo "Testing database connection..."
mysql -h "$DB_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" && echo "✓ Database connection successful" || { echo "✗ Database connection failed"; exit 1; }

# Step 3: Mount EFS file systems
echo "=== Step 3: Mounting EFS file systems ==="
DATA_EFS_ID="fs-075a2be536c08840c"
APP_EFS_ID="fs-0c60c5879a0dcecb1"

echo "Data EFS ID: $DATA_EFS_ID"
echo "App EFS ID: $APP_EFS_ID"

# Create mount points
mkdir -p /data /app

# Mount EFS file systems
echo "Mounting data EFS..."
if ! mountpoint -q /data; then
    mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/" /data
    echo "✓ Data EFS mounted successfully"
else
    echo "✓ Data EFS already mounted"
fi

echo "Mounting app EFS..."
if ! mountpoint -q /app; then
    mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "$APP_EFS_ID.efs.$REGION.amazonaws.com:/" /app
    echo "✓ App EFS mounted successfully"
else
    echo "✓ App EFS already mounted"
fi

# Add to fstab for persistence
echo "Adding EFS mounts to fstab..."
grep -q "$DATA_EFS_ID" /etc/fstab || echo "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/ /data nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab
grep -q "$APP_EFS_ID" /etc/fstab || echo "$APP_EFS_ID.efs.$REGION.amazonaws.com:/ /app nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab

# Set permissions
chown apache:apache /data /app
chmod 755 /data /app

# Verify mounts
echo "EFS mount verification:"
df -h | grep efs
mountpoint /data && echo "✓ /data is mounted" || echo "✗ /data is not mounted"
mountpoint /app && echo "✓ /app is mounted" || echo "✗ /app is not mounted"

# Step 4: Download Moodle
echo "=== Step 4: Downloading Moodle ==="
if [ ! -d "/app/moodle" ]; then
    echo "Downloading Moodle from GitHub..."
    cd /app
    git clone -b main --depth 1 https://github.com/moodle/moodle.git
    echo "✓ Moodle downloaded successfully"
else
    echo "✓ Moodle already exists"
fi

# Set ownership
chown -R apache:apache /app/moodle

# Step 5: Configure Apache
echo "=== Step 5: Configuring Apache ==="
cat > /etc/httpd/conf.d/moodle.conf << 'EOF'
<VirtualHost *:80>
    DocumentRoot /app/moodle
    ServerName localhost
    DirectoryIndex index.php index.html
    
    <Directory /app/moodle>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    # Security headers
    Header always set X-Content-Type-Options nosniff
    Header always set X-Frame-Options DENY
    Header always set X-XSS-Protection "1; mode=block"
    
    # Logging
    ErrorLog /var/log/httpd/moodle_error.log
    CustomLog /var/log/httpd/moodle_access.log combined
</VirtualHost>
EOF

# Disable default welcome page
mv /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/welcome.conf.disabled 2>/dev/null || echo "Welcome.conf already disabled"

# Step 6: Configure PHP
echo "=== Step 6: Configuring PHP ==="
# Update PHP settings for Moodle
sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php.ini
sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php.ini
sed -i 's/max_input_vars = .*/max_input_vars = 5000/' /etc/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' /etc/php.ini
sed -i 's/post_max_size = .*/post_max_size = 100M/' /etc/php.ini

# Step 7: Start services
echo "=== Step 7: Starting services ==="
systemctl enable httpd php-fpm
systemctl start httpd php-fpm
systemctl status httpd --no-pager
systemctl status php-fpm --no-pager

# Step 8: Prepare Moodle data directory
echo "=== Step 8: Preparing Moodle data directory ==="
mkdir -p /data/moodledata
chown apache:apache /data/moodledata
chmod 777 /data/moodledata

# Step 9: Get ALB URL
echo "=== Step 9: Getting ALB URL ==="
ALB_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='MoodleUrl'].OutputValue" --output text)
if [ -z "$ALB_URL" ] || [ "$ALB_URL" = "None" ]; then
    ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?contains(LoadBalancerName, 'Moodle')].LoadBalancerArn" --output text | head -1)
    if [ -n "$ALB_ARN" ]; then
        ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
        ALB_URL="http://$ALB_DNS_NAME"
    fi
fi
echo "ALB URL: $ALB_URL"

# Step 10: Install Moodle
echo "=== Step 10: Installing Moodle ==="
cd /app/moodle

if [ ! -f "config.php" ]; then
    echo "Running Moodle CLI installation..."
    sudo -u apache php admin/cli/install.php \
        --lang=en \
        --wwwroot="$ALB_URL" \
        --dataroot="/data/moodledata" \
        --dbtype=mariadb \
        --dbhost="$DB_ENDPOINT" \
        --dbname=moodle \
        --dbuser="$DB_USER" \
        --dbpass="$DB_PASS" \
        --dbport=3306 \
        --prefix=mdl_ \
        --fullname="Touchstone Institute" \
        --shortname="TSI" \
        --adminuser="moodle-admin" \
        --adminpass="TempPass123!" \
        --adminemail="it@tsin.ca" \
        --non-interactive \
        --agree-license
    
    echo "✓ Moodle installation completed!"
else
    echo "Moodle already installed, updating wwwroot..."
    sudo -u apache sed -i "s|\$CFG->wwwroot.*|\$CFG->wwwroot = '$ALB_URL';|" config.php
    echo "✓ Moodle configuration updated!"
fi

# Step 11: Create health check endpoint
echo "=== Step 11: Creating health check endpoint ==="
cat > /app/moodle/health.php << 'EOF'
<?php
// Simple health check for ALB
http_response_code(200);
echo 'OK';
?>
EOF
chown apache:apache /app/moodle/health.php
chmod 644 /app/moodle/health.php

# Step 12: Set final permissions
echo "=== Step 12: Setting final permissions ==="
chown -R apache:apache /app/moodle /data/moodledata
find /app/moodle -type f -exec chmod 644 {} \;
find /app/moodle -type d -exec chmod 755 {} \;
chmod -R 777 /data/moodledata

# Step 13: Restart services
echo "=== Step 13: Restarting services ==="
systemctl restart httpd php-fpm
sleep 5

# Step 14: Final health checks
echo "=== Step 14: Final health checks ==="
echo "Testing health endpoint..."
curl -f http://localhost/health.php && echo "✓ Health endpoint working" || echo "✗ Health endpoint failed"

echo "Testing Moodle login page..."
curl -f http://localhost/login/index.php >/dev/null 2>&1 && echo "✓ Moodle login page accessible" || echo "✗ Moodle login page failed"

echo "Testing main Moodle page..."
curl -f http://localhost/ >/dev/null 2>&1 && echo "✓ Main Moodle page accessible" || echo "✗ Main Moodle page failed"

# Step 15: Summary
echo "=== Installation Complete! ==="
echo "Completed at: $(date)"
echo ""
echo "🎉 Moodle Installation Summary:"
echo "✓ Packages installed"
echo "✓ EFS file systems mounted"
echo "✓ Apache and PHP configured"
echo "✓ Moodle downloaded and installed"
echo "✓ Health check endpoint created"
echo "✓ Services running"
echo ""
echo "🌐 Access Information:"
echo "Moodle URL: $ALB_URL"
echo "Admin username: moodle-admin"
echo "Admin password: TempPass123!"
echo "Admin email: it@tsin.ca"
echo ""
echo "⚠️  IMPORTANT: Change the admin password immediately after first login!"
echo ""
echo "📊 System Status:"
echo "EFS Mounts:"
df -h | grep efs
echo ""
echo "Services:"
systemctl is-active httpd && echo "✓ Apache: Active" || echo "✗ Apache: Inactive"
systemctl is-active php-fpm && echo "✓ PHP-FPM: Active" || echo "✗ PHP-FPM: Inactive"
