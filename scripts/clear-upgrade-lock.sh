#!/bin/bash
set -e

echo "=== Clearing Moodle Upgrade Lock ==="
echo ""

REGION="${REGION:-ca-central-1}"

# Get database credentials
echo "Getting database credentials..."
DB_SECRET_ARN=$(aws secretsmanager list-secrets --region $REGION --query 'SecretList[?contains(Name, `TrainingMoodleDbSecret`)].ARN' --output text)
DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region $REGION --query SecretString --output text)
DB_HOST=$(echo "$DB_CREDS" | jq -r .host)
DB_USER=$(echo "$DB_CREDS" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS" | jq -r .password)

echo "Database: $DB_HOST"
echo ""

# Clear the upgrade lock
echo "Clearing upgraderunning flag..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "DELETE FROM mdl_config WHERE name='upgraderunning';" 2>&1 | grep -v Warning || true

echo "✓ Upgrade lock cleared"
echo ""

# Purge caches
echo "Purging caches..."
cd /app/moodle
sudo -u apache php admin/cli/purge_caches.php

echo ""
echo "✓ Complete! Site should now be accessible."
echo ""

# Check current version
echo "Current database version:"
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "SELECT value FROM mdl_config WHERE name='release';" -s -N 2>&1 | grep -v Warning

echo ""

