#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Fix EFS Mounts and Download Training Backups                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Get EFS IDs from environment or set defaults
APP_EFS_ID="${APP_EFS_ID:-fs-0f028c598179df080}"
DATA_EFS_ID="${DATA_EFS_ID:-fs-0834ed0a16ccbb966}"
REGION="${REGION:-ca-central-1}"

echo "Configuration:"
echo "  App EFS: $APP_EFS_ID"
echo "  Data EFS: $DATA_EFS_ID"
echo "  Region: $REGION"
echo ""

# SFTP Configuration
SFTP_HOST="sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
SFTP_USER="etraintouchstone"
S3_BUCKET="__S3_BUCKET__"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Check Current Mount Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

APP_MOUNTED=0
DATA_MOUNTED=0

if mountpoint -q /app 2>/dev/null; then
    echo "✓ /app is already mounted"
    APP_MOUNTED=1
else
    echo "✗ /app is NOT mounted"
fi

if mountpoint -q /data 2>/dev/null; then
    echo "✓ /data is already mounted"
    DATA_MOUNTED=1
else
    echo "✗ /data is NOT mounted"
fi

echo ""
echo "Current mounts:"
mount | grep -E 'efs|nfs4' || echo "  No EFS/NFS4 mounts found"
echo ""

# Install EFS utils if needed
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Ensure EFS Utils Installed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! command -v mount.efs &> /dev/null; then
    echo "Installing amazon-efs-utils..."
    sudo yum install -y amazon-efs-utils nfs-utils
    echo "✓ EFS utils installed"
else
    echo "✓ EFS utils already installed"
fi
echo ""

# Create mount directories
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Create Mount Directories"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sudo mkdir -p /app /data
echo "✓ Directories created"
echo ""

# Mount EFS if not already mounted
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Mount EFS File Systems"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Mount /app if needed
if [ $APP_MOUNTED -eq 0 ]; then
    echo "Mounting /app (EFS: $APP_EFS_ID)..."
    
    # Try with EFS helper first
    if sudo mount -t efs -o tls,iam "$APP_EFS_ID:/" /app 2>/dev/null; then
        echo "✓ /app mounted using EFS helper"
    # Fallback to NFS4
    elif sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "$APP_EFS_ID.efs.$REGION.amazonaws.com:/" /app; then
        echo "✓ /app mounted using NFS4"
    else
        echo "✗ Failed to mount /app"
        exit 1
    fi
else
    echo "✓ /app already mounted, skipping"
fi

# Mount /data if needed
if [ $DATA_MOUNTED -eq 0 ]; then
    echo "Mounting /data (EFS: $DATA_EFS_ID)..."
    
    # Try with EFS helper first
    if sudo mount -t efs -o tls,iam "$DATA_EFS_ID:/" /data 2>/dev/null; then
        echo "✓ /data mounted using EFS helper"
    # Fallback to NFS4
    elif sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "$DATA_EFS_ID.efs.$REGION.amazonaws.com:/" /data; then
        echo "✓ /data mounted using NFS4"
    else
        echo "✗ Failed to mount /data"
        exit 1
    fi
else
    echo "✓ /data already mounted, skipping"
fi

echo ""
echo "Verifying mounts..."
if ! mountpoint -q /app; then
    echo "✗ /app mount verification failed!"
    exit 1
fi
if ! mountpoint -q /data; then
    echo "✗ /data mount verification failed!"
    exit 1
fi

echo "✓ Both EFS file systems mounted successfully"
echo ""

# Show disk usage
echo "Disk usage:"
df -h | grep -E '/app|/data'
echo ""

# Create backup directory on EFS
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Create Backup Directory on EFS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sudo mkdir -p /data/training-backups
sudo chmod 777 /data/training-backups
cd /data/training-backups

echo "✓ Backup directory ready: /data/training-backups/"
echo ""

# Install lftp if needed
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Install LFTP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! command -v lftp &> /dev/null; then
    echo "Installing lftp..."
    sudo yum install -y lftp
    echo "✓ lftp installed"
else
    echo "✓ lftp already installed"
fi
echo ""

# Download SSH key from S3
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Download SSH Key"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p /tmp/keys
aws s3 cp "s3://$S3_BUCKET/keys/etraintouchstone" /tmp/keys/etraintouchstone --region "$REGION"
chmod 600 /tmp/keys/etraintouchstone

echo "✓ SSH key downloaded and permissions set"
echo ""

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

# Download all files
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 8: Download Backup Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Download database
download_file "mdl_etraintouchstone.sql" "Database SQL (197 MB)"

# Download app code
download_file "etraintouchstone-learn-app.tar.gz" "App Code (84.3 MB)"

# Download moodledata (large file)
download_file "etraintouchstone-learn-moodledata.tar.gz" "Moodledata (68.9 GB)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ ALL DOWNLOADS COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Files downloaded to: /data/training-backups/ (on EFS)"
echo ""
echo "File listing:"
ls -lh /data/training-backups/
echo ""
echo "Disk usage:"
df -h /data
echo ""
echo "✓ Ready for Phase 4: Restore Database and Files"

