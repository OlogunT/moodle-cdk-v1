#!/bin/bash
set -e

echo "=== Enabling Debug Mode on Training Moodle ==="
echo ""

CONFIG_FILE="/app/moodle/config.php"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.php not found at $CONFIG_FILE"
    exit 1
fi

echo "Step 1: Backing up config.php..."
BACKUP_FILE="$CONFIG_FILE.backup.$(date +%s)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "Backup created at: $BACKUP_FILE"
echo ""

echo "Step 2: Adding debug settings to config.php..."

# Check if debug settings already exist
if grep -q "CFG->debug" "$CONFIG_FILE"; then
    echo "Debug settings already present, updating..."
    # Remove existing debug settings
    sed -i '/\$CFG->debug/d' "$CONFIG_FILE"
    sed -i '/\$CFG->debugdisplay/d' "$CONFIG_FILE"
    sed -i '/\$CFG->debugstringkeys/d' "$CONFIG_FILE"
    sed -i '/\$CFG->debugpageinfo/d' "$CONFIG_FILE"
    sed -i '/^\/\/ Debug settings$/d' "$CONFIG_FILE"
else
    echo "Adding new debug settings..."
fi

# Insert debug settings before require_once
sed -i "/require_once.*lib\/setup\.php/i \\
// Debug settings\\
\\\$CFG->debug = (E_ALL | E_STRICT);\\
\\\$CFG->debugdisplay = 1;\\
\\\$CFG->debugstringkeys = true;\\
\\\$CFG->debugpageinfo = true;" "$CONFIG_FILE"

echo "Debug settings added"
echo ""

echo "Step 3: Verifying configuration..."
echo "--- Debug settings in config.php ---"
grep -A 4 "// Debug settings" "$CONFIG_FILE" || echo "Settings added before require_once"
echo ""

echo "Step 4: Purging Moodle caches..."
cd /app/moodle
sudo -u apache php admin/cli/purge_caches.php 2>&1 | head -15
echo ""

echo "SUCCESS: Debug mode enabled!"
echo ""
echo "Debug settings enabled:"
echo "  - \$CFG->debug = (E_ALL | E_STRICT)"
echo "  - \$CFG->debugdisplay = 1"
echo "  - \$CFG->debugstringkeys = true"
echo "  - \$CFG->debugpageinfo = true"
echo ""
echo "Backup saved to: $BACKUP_FILE"

