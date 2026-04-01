#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Download Training Backups Using SFTP (Batch Mode)           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
SFTP_HOST="sftp-prod2-ca-cenral-1.lambdasolutionscloud.net"
SFTP_USER="etraintouchstone"
SSH_KEY="/tmp/keys/etraintouchstone"
DOWNLOAD_DIR="/data/training-backups"

echo "Configuration:"
echo "  SFTP Host: $SFTP_HOST"
echo "  SFTP User: $SFTP_USER"
echo "  SSH Key: $SSH_KEY"
echo "  Download Dir: $DOWNLOAD_DIR"
echo ""

# Verify EFS is mounted
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Verify EFS Mount"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! mountpoint -q /data; then
    echo "✗ /data is NOT mounted!"
    exit 1
fi

echo "✓ /data is mounted"
df -h /data
echo ""

# Create download directory
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Prepare Download Directory"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"
echo "✓ Working directory: $(pwd)"
echo ""

# Verify SSH key
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Verify SSH Key"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ ! -f "$SSH_KEY" ]; then
    echo "✗ SSH key not found: $SSH_KEY"
    exit 1
fi

ls -la "$SSH_KEY"
echo "✓ SSH key found"
echo ""

# Function to download a file using SFTP batch mode
download_file() {
    local remote_file=$1
    local description=$2
    local local_file="$DOWNLOAD_DIR/$remote_file"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Downloading: $description"
    echo "  Remote: $remote_file"
    echo "  Local: $local_file"
    echo ""
    
    # Check if file already exists
    if [ -f "$local_file" ]; then
        local size=$(du -h "$local_file" | cut -f1)
        echo "  ⚠ File already exists: $size"
        echo "  ✓ Skipping download"
        echo ""
        return 0
    fi
    
    # Create SFTP batch file
    cat > /tmp/sftp-batch-$$.txt << EOF
get $remote_file
bye
EOF
    
    echo "  Starting download..."
    
    # Execute SFTP
    if sftp -i "$SSH_KEY" -o StrictHostKeyChecking=no -b /tmp/sftp-batch-$$.txt "$SFTP_USER@$SFTP_HOST"; then
        rm -f /tmp/sftp-batch-$$.txt
        
        if [ -f "$local_file" ]; then
            local final_size=$(du -h "$local_file" | cut -f1)
            echo ""
            echo "  ✓ Download complete: $final_size"
            echo ""
            return 0
        else
            echo ""
            echo "  ✗ Download failed - file not found after transfer"
            echo ""
            return 1
        fi
    else
        rm -f /tmp/sftp-batch-$$.txt
        echo ""
        echo "  ✗ SFTP command failed"
        echo ""
        return 1
    fi
}

# Download all files
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Download Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Download database (197 MB)
download_file "mdl_etraintouchstone.sql" "Database SQL (197 MB)"

# Download app code (84.3 MB)
download_file "etraintouchstone-learn-app.tar.gz" "App Code (84.3 MB)"

# Download moodledata (68.9 GB) - this will take a while
download_file "etraintouchstone-learn-moodledata.tar.gz" "Moodledata (68.9 GB)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ ALL DOWNLOADS COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Files downloaded to: $DOWNLOAD_DIR"
echo ""
echo "File listing:"
ls -lh "$DOWNLOAD_DIR"
echo ""
echo "Disk usage:"
df -h /data
echo ""
echo "✓ Ready for Phase 4: Restore Database and Files"

