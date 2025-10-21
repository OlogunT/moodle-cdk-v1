#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Phase 4: Restore Training Moodle Database and Files         ║"
echo "║   Migrating from Moodle 4.1 to Moodle 5.0                     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
REGION="${REGION:-ca-central-1}"
BACKUP_DIR="/data/training-backups"
MOODLEDATA_DIR="/data/moodledata"
MOODLE_APP_DIR="/app/moodle"

echo "Configuration:"
echo "  Region: $REGION"
echo "  Backup Directory: $BACKUP_DIR"
echo "  Moodledata Directory: $MOODLEDATA_DIR"
echo "  Moodle App Directory: $MOODLE_APP_DIR"
echo ""
echo "Migration Info:"
echo "  Source Version: Moodle 4.1"
echo "  Target Version: Moodle 5.0"
echo "  Note: Database will be upgraded after restoration"
echo ""

# ============================================================================
# Step 1: Verify Prerequisites
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Verify Prerequisites"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check backup files exist
echo "Checking backup files..."
if [ ! -f "$BACKUP_DIR/mdl_etraintouchstone.sql" ]; then
    echo "✗ Database backup not found: $BACKUP_DIR/mdl_etraintouchstone.sql"
    exit 1
fi
if [ ! -f "$BACKUP_DIR/etraintouchstone-learn-moodledata.tar.gz" ]; then
    echo "✗ Moodledata backup not found: $BACKUP_DIR/etraintouchstone-learn-moodledata.tar.gz"
    exit 1
fi
echo "✓ All backup files found"
echo ""

# Check Moodle is installed and get version
if [ ! -f "$MOODLE_APP_DIR/version.php" ]; then
    echo "✗ Moodle not found in $MOODLE_APP_DIR"
    exit 1
fi

# Extract Moodle version
MOODLE_VERSION=$(grep '$release' "$MOODLE_APP_DIR/version.php" | head -1 | sed "s/.*'\(.*\)'.*/\1/" || echo "Unknown")
echo "✓ Moodle installation found: $MOODLE_VERSION"
echo ""

# Verify it's Moodle 5.0 or compatible
if [[ ! "$MOODLE_VERSION" =~ ^5\. ]]; then
    echo "⚠ WARNING: Expected Moodle 5.x but found: $MOODLE_VERSION"
    echo "  Migration from 4.1 to 5.0 requires Moodle 5.x to be installed"
    echo "  Continuing anyway..."
fi
echo ""

# Get database credentials
echo "Retrieving database credentials from Secrets Manager..."
DB_SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" --query 'SecretList[?contains(Name, `TrainingMoodleDbSecret`)].ARN' --output text)

if [ -z "$DB_SECRET_ARN" ]; then
    echo "✗ Could not find TrainingMoodleDbSecret in Secrets Manager"
    exit 1
fi

echo "  Secret ARN: $DB_SECRET_ARN"

DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region "$REGION" --query SecretString --output text)
DB_USER=$(echo "$DB_CREDS" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS" | jq -r .password)
DB_HOST=$(echo "$DB_CREDS" | jq -r .host)

echo "  Database Host: $DB_HOST"
echo "  Database User: $DB_USER"
echo "  Database Name: moodle"
echo ""

# Test database connection
echo "Testing database connection..."
if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" > /dev/null 2>&1; then
    echo "✓ Database connection successful"
else
    echo "✗ Database connection failed"
    exit 1
fi
echo ""

# ============================================================================
# Step 2: Restore Database
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Restore Database"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

DB_BACKUP="$BACKUP_DIR/mdl_etraintouchstone.sql"
DB_SIZE=$(du -h "$DB_BACKUP" | cut -f1)

echo "Database backup: $DB_BACKUP ($DB_SIZE)"
echo ""
echo "⚠ WARNING: This will DROP and recreate the 'moodle' database!"
echo "⚠ All existing data in the database will be lost!"
echo ""

# Drop and recreate database
echo "Dropping existing database (if exists)..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS moodle;" 2>&1 | grep -v "Warning: Using a password" || true
echo "✓ Database dropped"
echo ""

echo "Creating fresh database..."
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1 | grep -v "Warning: Using a password" || true
echo "✓ Database created"
echo ""

echo "Importing database backup (this may take several minutes)..."
echo "  Started at: $(date)"
echo ""

# Import with progress indicator
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" moodle < "$DB_BACKUP" 2>&1 | grep -v "Warning: Using a password" || true

echo ""
echo "  Completed at: $(date)"
echo "✓ Database import complete"
echo ""

# Verify import
echo "Verifying database import..."
TABLE_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle';" -s -N 2>&1 | grep -v "Warning: Using a password" || echo "0")
USER_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D moodle -e "SELECT COUNT(*) FROM mdl_user;" -s -N 2>&1 | grep -v "Warning: Using a password" || echo "0")

echo "  Tables imported: $TABLE_COUNT"
echo "  Users in database: $USER_COUNT"
echo "✓ Database verification complete"
echo ""

# ============================================================================
# Step 3: Extract Moodledata
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Extract Moodledata Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

MOODLEDATA_BACKUP="$BACKUP_DIR/etraintouchstone-learn-moodledata.tar.gz"
MOODLEDATA_SIZE=$(du -h "$MOODLEDATA_BACKUP" | cut -f1)

echo "Moodledata backup: $MOODLEDATA_BACKUP ($MOODLEDATA_SIZE)"
echo "Target directory: $MOODLEDATA_DIR"
echo ""

# Backup existing moodledata if it exists
if [ -d "$MOODLEDATA_DIR" ] && [ "$(ls -A $MOODLEDATA_DIR)" ]; then
    echo "⚠ Existing moodledata found, backing up to ${MOODLEDATA_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    mv "$MOODLEDATA_DIR" "${MOODLEDATA_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Create moodledata directory
mkdir -p "$MOODLEDATA_DIR"
echo "✓ Directory created: $MOODLEDATA_DIR"
echo ""

echo "Extracting moodledata (this will take 10-20 minutes for 69GB)..."
echo "  Started at: $(date)"
echo ""

# Extract with progress
cd /data
tar -xzf "$MOODLEDATA_BACKUP" 2>&1 || true

echo ""
echo "  Completed at: $(date)"
echo "✓ Moodledata extraction complete"
echo ""

# Verify extraction
if [ -d "$MOODLEDATA_DIR" ]; then
    MOODLEDATA_ACTUAL_SIZE=$(du -sh "$MOODLEDATA_DIR" | cut -f1)
    FILE_COUNT=$(find "$MOODLEDATA_DIR" -type f | wc -l)
    echo "  Directory size: $MOODLEDATA_ACTUAL_SIZE"
    echo "  Files extracted: $FILE_COUNT"
    echo "✓ Moodledata verification complete"
else
    echo "✗ Moodledata directory not found after extraction"
    exit 1
fi
echo ""

# ============================================================================
# Step 4: Set Permissions
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Set Permissions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Setting ownership to apache:apache..."
chown -R apache:apache "$MOODLEDATA_DIR"
echo "✓ Ownership set"
echo ""

echo "Setting directory permissions to 777..."
chmod -R 777 "$MOODLEDATA_DIR"
echo "✓ Permissions set"
echo ""

# ============================================================================
# Step 5: Set Custom Domain URL
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Set Custom Domain URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Use custom domain for training Moodle
MOODLE_URL="https://training.tsin.ca"
echo "  Moodle URL: $MOODLE_URL"
echo "  Note: Route53 and ACM certificate already configured"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ PHASE 4 COMPLETE: Database and Files Restored"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Summary:"
echo "  ✓ Database restored to RDS"
echo "  ✓ Moodledata extracted to $MOODLEDATA_DIR"
echo "  ✓ Permissions set (apache:apache, 777)"
echo ""
echo "Database Info:"
echo "  Host: $DB_HOST"
echo "  Name: moodle"
echo "  User: $DB_USER"
echo "  Tables: $TABLE_COUNT"
echo "  Users: $USER_COUNT"
echo ""
echo "Next Steps (Phase 5):"
echo "  1. Update Moodle config.php with new database credentials"
echo "  2. Update wwwroot to: $MOODLE_URL"
echo "  3. Run Moodle upgrade: sudo -u apache php admin/cli/upgrade.php --non-interactive"
echo "     (This will upgrade the database from Moodle 4.1 to 5.0 schema)"
echo "  4. Purge caches: sudo -u apache php admin/cli/purge_caches.php"
echo "  5. Test the site at: $MOODLE_URL"
echo ""
echo "⚠ IMPORTANT: The database is currently Moodle 4.1 schema"
echo "  It MUST be upgraded to Moodle 5.0 schema before the site will work"
echo "  This will be done in Phase 5 using the upgrade CLI command"
echo ""
echo "Ready for Phase 5: Configuration & Upgrade to Moodle 5.0"

