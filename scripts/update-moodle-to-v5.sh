#!/bin/bash
set -e

echo "=== Updating Moodle Code to Version 5.0 ==="
echo ""

cd /app/moodle

echo "Current version:"
grep '$release' version.php | head -1
echo ""

echo "Fetching latest code..."
git fetch --all

echo "Checking out MOODLE_500_STABLE..."
git checkout MOODLE_500_STABLE

echo "Pulling latest changes..."
git pull origin MOODLE_500_STABLE

echo ""
echo "New version:"
grep '$release' version.php | head -1
echo ""

echo "Setting permissions..."
chown -R apache:apache /app/moodle

echo ""
echo "✓ Moodle code updated to version 5.0"
echo ""
echo "Now run the upgrade via web interface at:"
echo "  https://training.tsin.ca/admin/index.php"

