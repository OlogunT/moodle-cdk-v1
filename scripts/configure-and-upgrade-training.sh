#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Phase 5: Configure & Upgrade Training Moodle               ║"
echo "║   Upgrade Database from Moodle 4.1 to 5.0                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
REGION="${REGION:-ca-central-1}"
MOODLE_APP_DIR="/app/moodle"
MOODLEDATA_DIR="/data/moodledata"
CONFIG_FILE="$MOODLE_APP_DIR/config.php"
MOODLE_URL="https://training.tsin.ca"

echo "Configuration:"
echo "  Region: $REGION"
echo "  Moodle Directory: $MOODLE_APP_DIR"
echo "  Moodledata Directory: $MOODLEDATA_DIR"
echo "  Moodle URL: $MOODLE_URL"
echo ""

# ============================================================================
# Step 1: Verify Prerequisites
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Verify Prerequisites"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check Moodle installation
if [ ! -d "$MOODLE_APP_DIR" ]; then
    echo "✗ Moodle directory not found: $MOODLE_APP_DIR"
    exit 1
fi

if [ ! -f "$MOODLE_APP_DIR/version.php" ]; then
    echo "✗ Moodle version.php not found"
    exit 1
fi

MOODLE_VERSION=$(grep '$release' "$MOODLE_APP_DIR/version.php" | head -1 | sed "s/.*'\(.*\)'.*/\1/" || echo "Unknown")
echo "✓ Moodle installation found: $MOODLE_VERSION"
echo ""

# Check moodledata
if [ ! -d "$MOODLEDATA_DIR" ]; then
    echo "✗ Moodledata directory not found: $MOODLEDATA_DIR"
    exit 1
fi

MOODLEDATA_SIZE=$(du -sh "$MOODLEDATA_DIR" | cut -f1)
echo "✓ Moodledata found: $MOODLEDATA_SIZE"
echo ""

# Get database credentials
echo "Retrieving database credentials from Secrets Manager..."
DB_SECRET_ARN=$(aws secretsmanager list-secrets --region $REGION --query 'SecretList[?contains(Name, `TrainingMoodleDbSecret`)].ARN' --output text)

if [ -z "$DB_SECRET_ARN" ]; then
    echo "✗ Could not find TrainingMoodleDbSecret"
    exit 1
fi

DB_CREDS=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --region $REGION --query SecretString --output text)
DB_HOST=$(echo "$DB_CREDS" | jq -r .host)
DB_USER=$(echo "$DB_CREDS" | jq -r .username)
DB_PASS=$(echo "$DB_CREDS" | jq -r .password)
DB_NAME="moodle"

echo "  Database Host: $DB_HOST"
echo "  Database User: $DB_USER"
echo "  Database Name: $DB_NAME"
echo ""

# Test database connection
echo "Testing database connection..."
if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT 1;" > /dev/null 2>&1; then
    echo "✓ Database connection successful"
else
    echo "✗ Database connection failed"
    exit 1
fi
echo ""

# ============================================================================
# Step 2: Backup Existing Config (if exists)
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Backup Existing Config"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$CONFIG_FILE" ]; then
    BACKUP_CONFIG="$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_CONFIG"
    echo "✓ Existing config backed up to: $BACKUP_CONFIG"
else
    echo "✓ No existing config.php found"
fi
echo ""

# ============================================================================
# Step 3: Create/Update config.php
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Create/Update config.php"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Creating new config.php..."

cat > "$CONFIG_FILE" << 'EOFCONFIG'
<?php  // Moodle configuration file

unset($CFG);
global $CFG;
$CFG = new stdClass();

EOFCONFIG

# Add database configuration
cat >> "$CONFIG_FILE" << EOFCONFIG
\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '$DB_HOST';
\$CFG->dbname    = '$DB_NAME';
\$CFG->dbuser    = '$DB_USER';
\$CFG->dbpass    = '$DB_PASS';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => 3306,
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

EOFCONFIG

# Add Moodle configuration
cat >> "$CONFIG_FILE" << EOFCONFIG
\$CFG->wwwroot   = '$MOODLE_URL';
\$CFG->dataroot  = '$MOODLEDATA_DIR';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 02777;

// SSL proxy configuration for ALB
\$CFG->sslproxy = true;

// Performance settings
\$CFG->session_handler_class = '\core\session\file';
\$CFG->session_file_save_path = '$MOODLEDATA_DIR/sessions';

// Disable email during upgrade
\$CFG->noemailever = true;

require_once(__DIR__ . '/lib/setup.php');
EOFCONFIG

echo "✓ config.php created"
echo ""

# Set permissions
chown apache:apache "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"
echo "✓ Permissions set (apache:apache, 640)"
echo ""

# ============================================================================
# Step 4: Verify Database Schema Version
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Verify Database Schema Version"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

DB_VERSION=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT value FROM mdl_config WHERE name='version';" -s -N 2>&1 | grep -v Warning || echo "Unknown")
DB_RELEASE=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT value FROM mdl_config WHERE name='release';" -s -N 2>&1 | grep -v Warning || echo "Unknown")

echo "  Current Database Version: $DB_VERSION"
echo "  Current Database Release: $DB_RELEASE"
echo "  Target Moodle Version: $MOODLE_VERSION"
echo ""

if [[ "$DB_RELEASE" =~ ^4\.1 ]]; then
    echo "✓ Database is Moodle 4.1 - upgrade required"
elif [[ "$DB_RELEASE" =~ ^5\. ]]; then
    echo "⚠ Database is already Moodle 5.x - upgrade may not be needed"
else
    echo "⚠ Database version: $DB_RELEASE"
fi
echo ""

# ============================================================================
# Step 5: Run Moodle Upgrade
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Run Moodle Upgrade (4.1 → 5.0)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "⚠ IMPORTANT: This will upgrade the database schema from Moodle 4.1 to 5.0"
echo "  This process may take 5-15 minutes depending on database size"
echo ""

echo "Starting upgrade..."
echo "  Started at: $(date)"
echo ""

# Run upgrade as apache user
cd "$MOODLE_APP_DIR"

if sudo -u apache php admin/cli/upgrade.php --non-interactive 2>&1 | tee /tmp/moodle-upgrade.log; then
    echo ""
    echo "✓ Moodle upgrade completed successfully"
else
    echo ""
    echo "✗ Moodle upgrade failed - check /tmp/moodle-upgrade.log"
    exit 1
fi

echo "  Completed at: $(date)"
echo ""

# ============================================================================
# Step 6: Verify Upgrade
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Verify Upgrade"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

NEW_DB_VERSION=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT value FROM mdl_config WHERE name='version';" -s -N 2>&1 | grep -v Warning || echo "Unknown")
NEW_DB_RELEASE=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT value FROM mdl_config WHERE name='release';" -s -N 2>&1 | grep -v Warning || echo "Unknown")

echo "  New Database Version: $NEW_DB_VERSION"
echo "  New Database Release: $NEW_DB_RELEASE"
echo ""

if [[ "$NEW_DB_RELEASE" =~ ^5\. ]]; then
    echo "✓ Database successfully upgraded to Moodle 5.x"
else
    echo "⚠ Database release: $NEW_DB_RELEASE (expected 5.x)"
fi
echo ""

# ============================================================================
# Step 7: Purge Caches
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Purge Caches"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Purging all caches..."
if sudo -u apache php admin/cli/purge_caches.php 2>&1; then
    echo "✓ Caches purged successfully"
else
    echo "⚠ Cache purge had warnings (this is usually OK)"
fi
echo ""

# ============================================================================
# Step 8: Re-enable Email
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 8: Re-enable Email"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Removing noemailever setting from config.php..."
sed -i '/\$CFG->noemailever/d' "$CONFIG_FILE"
echo "✓ Email re-enabled"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Phase 5 Complete: Configuration & Upgrade"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Summary:"
echo "  ✓ config.php created with correct settings"
echo "  ✓ Database upgraded from Moodle 4.1 to 5.0"
echo "  ✓ Caches purged"
echo "  ✓ Email re-enabled"
echo ""
echo "Database Info:"
echo "  Previous Version: $DB_RELEASE"
echo "  Current Version: $NEW_DB_RELEASE"
echo ""
echo "Moodle URL: $MOODLE_URL"
echo ""
echo "Next Steps:"
echo "  1. Test the site: curl -sL $MOODLE_URL | grep -i 'log in'"
echo "  2. Access the site in browser: $MOODLE_URL"
echo "  3. Verify all courses and users are present"
echo "  4. Test login functionality"
echo "  5. Configure email settings (SES) if needed"
echo ""
echo "Logs:"
echo "  Upgrade log: /tmp/moodle-upgrade.log"
echo "  Apache logs: /var/log/httpd/"
echo ""

