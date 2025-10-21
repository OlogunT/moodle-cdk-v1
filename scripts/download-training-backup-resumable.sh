#!/bin/bash
#
# Resumable SFTP download script using lftp
# This script can resume interrupted downloads
#

set -e

# Configuration
SFTP_HOST="sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
SFTP_USER="etraintouchstone"
KEY_FILE="/mnt/c/github/moodle-cdk0/source/etraintouchstone"
BACKUP_DIR="/mnt/c/github/moodle-cdk0/backups/training"

# Files to download
DB_FILE="mdl_etraintouchstone.sql"
DATA_FILE="etraintouchstone-learn-moodledata.tar.gz"
APP_FILE="etraintouchstone-learn-app.tar.gz"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Training Moodle Resumable Backup Download (lftp)            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Check if lftp is installed
if ! command -v lftp &> /dev/null; then
    echo "❌ lftp is not installed"
    echo "Installing lftp..."
    sudo apt-get update -qq
    sudo apt-get install -y lftp
fi

echo "✓ lftp is available"
echo ""

# Fix key permissions
chmod 600 "$KEY_FILE"

# Function to download file with resume support
download_file() {
    local remote_file=$1
    local local_file="$BACKUP_DIR/$remote_file"
    local file_desc=$2
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Downloading: $file_desc"
    echo "  Remote: $remote_file"
    echo "  Local:  $local_file"
    echo ""
    
    # Check if file already exists and get size
    if [ -f "$local_file" ]; then
        local_size=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null || echo "0")
        echo "  ⚠ Partial file exists: $(numfmt --to=iec-i --suffix=B $local_size 2>/dev/null || echo "$local_size bytes")"
        echo "  ✓ Will resume download..."
        echo ""
    fi
    
    # Download with lftp (supports resume automatically)
    lftp -e "
        set sftp:connect-program 'ssh -a -x -i $KEY_FILE -o StrictHostKeyChecking=no';
        set net:max-retries 10;
        set net:timeout 30;
        set net:reconnect-interval-base 5;
        set net:reconnect-interval-multiplier 1;
        set xfer:clobber on;
        connect sftp://$SFTP_USER@$SFTP_HOST;
        get -c '$remote_file' -o '$local_file';
        bye
    "
    
    if [ $? -eq 0 ] && [ -f "$local_file" ]; then
        file_size=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null || echo "0")
        echo ""
        echo "  ✓ Download complete!"
        echo "  ✓ File size: $(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "$file_size bytes")"
        echo ""
        return 0
    else
        echo ""
        echo "  ✗ Download failed!"
        echo ""
        return 1
    fi
}

# Download files
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Starting downloads..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Download database
download_file "$DB_FILE" "Database SQL (197 MB)"

# Download moodledata
download_file "$DATA_FILE" "Moodledata Archive (68.9 GB)"

# Download app code
download_file "$APP_FILE" "App Code (84.3 MB)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All downloads complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# List downloaded files
echo "Downloaded files:"
ls -lh "$BACKUP_DIR"
echo ""

echo "Next step: Upload to S3"
echo "  Run: pwsh scripts/upload-training-to-s3.ps1"
echo ""

