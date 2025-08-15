#!/bin/bash
set -e

echo "Fixing EFS mount issues..."

# Mount EFS file systems
echo "Mounting EFS file systems..."
sudo mount -t efs fs-075a2be536c08840c:/ /data
sudo mount -t efs fs-0c60c5879a0dcecb1:/ /app

# Set permissions
echo "Setting permissions..."
sudo chown apache:apache /data /app
sudo chmod 755 /data /app

# Verify mounts
echo "Verifying mounts..."
mount | grep efs
ls -la /data /app

echo "EFS mount fix completed!"
