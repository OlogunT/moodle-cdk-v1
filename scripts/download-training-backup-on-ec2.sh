#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Downloading Training Moodle Backups from SFTP                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Configuration (will be replaced by PowerShell script)
SFTP_HOST="sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
SFTP_USER="etraintouchstone"
S3_BUCKET="__S3_BUCKET__"
REGION="__REGION__"

# Download SSH key from S3
echo "Downloading SSH key from S3..."
mkdir -p /tmp/keys
aws s3 cp "s3://$S3_BUCKET/keys/etraintouchstone" /tmp/keys/etraintouchstone --region $REGION
chmod 600 /tmp/keys/etraintouchstone
echo "✓ SSH key downloaded"
echo ""

# Install lftp if not present (for resumable downloads)
if ! command -v lftp &> /dev/null; then
    echo "Installing lftp..."
    sudo yum install -y lftp
    echo "✓ lftp installed"
fi
echo ""

# Verify EFS is mounted
echo "Verifying EFS mounts..."
if ! mountpoint -q /app; then
    echo "✗ /app is not mounted! EFS may not be ready."
    exit 1
fi
if ! mountpoint -q /data; then
    echo "✗ /data is not mounted! EFS may not be ready."
    exit 1
fi
echo "✓ /app is mounted"
echo "✓ /data is mounted"
df -h | grep -E '/app|/data'
echo ""

# Create download directory on /data (EFS) for backups
mkdir -p /data/training-backups
cd /data/training-backups

# Function to download with lftp (resumable)
download_file() {
    local remote_file=$1
    local description=$2
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Downloading: $description"
    echo "  Remote: $remote_file"
    echo "  Local: /data/training-backups/$remote_file (EFS)"
    echo ""
    
    if [ -f "$remote_file" ]; then
        local size=$(du -h "$remote_file" | cut -f1)
        echo "  ⚠ Partial file exists: $size"
        echo "  ✓ Will resume download..."
        echo ""
    fi
    
    lftp -e "
        set sftp:connect-program 'ssh -a -x -i /tmp/keys/etraintouchstone -o StrictHostKeyChecking=no';
        set net:max-retries 10;
        set net:timeout 30;
        set net:reconnect-interval-base 5;
        set xfer:clobber on;
        connect sftp://$SFTP_USER@$SFTP_HOST;
        get -c '$remote_file';
        bye
    "
    
    if [ -f "$remote_file" ]; then
        local final_size=$(du -h "$remote_file" | cut -f1)
        echo ""
        echo "  ✓ Download complete: $final_size"
        echo ""
        return 0
    else
        echo ""
        echo "  ✗ Download failed"
        echo ""
        return 1
    fi
}

# Download files
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Starting downloads..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

download_file "mdl_etraintouchstone.sql" "Database SQL (197 MB)"
download_file "etraintouchstone-learn-moodledata.tar.gz" "Moodledata Archive (68.9 GB)"
download_file "etraintouchstone-learn-app.tar.gz" "App Code (84.3 MB)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All downloads complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# List downloaded files
echo "Downloaded files:"
ls -lh /data/training-backups/
echo ""

echo "Files are ready in /data/training-backups/ (on EFS)"
echo "Next: Run restoration scripts to restore database and moodledata"
echo ""

