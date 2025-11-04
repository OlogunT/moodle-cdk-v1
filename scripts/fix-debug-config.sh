#!/bin/bash
# Fix the Moodle config.php file and add debug settings properly

set -e

CONFIG_FILE="/app/moodle/config.php"

echo "=== Fixing Moodle Config and Enabling Debug Mode ==="
echo ""

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.php not found at $CONFIG_FILE"
    exit 1
fi

# Backup the current file
echo "Step 1: Creating backup..."
BACKUP_FILE="$CONFIG_FILE.backup.$(date +%s)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "Backup created at: $BACKUP_FILE"
echo ""

# Create a Python script to properly edit the config
echo "Step 2: Creating Python script to edit config..."
cat > /tmp/fix_config.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re

config_file = '/app/moodle/config.php'

# Read the config file
with open(config_file, 'r') as f:
    content = f.read()

# Remove any existing debug settings
lines = content.split('\n')
new_lines = []
for line in lines:
    if '$CFG->debug' not in line and \
       '$CFG->debugdisplay' not in line and \
       '$CFG->debugstringkeys' not in line and \
       '$CFG->debugpageinfo' not in line and \
       '// Debug settings' not in line:
        new_lines.append(line)

content = '\n'.join(new_lines)

# Find the require_once line and insert debug settings before it
debug_settings = """
// Debug settings
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;
$CFG->debugstringkeys = true;
$CFG->debugpageinfo = true;
"""

# Replace the require_once line with debug settings + require_once
content = content.replace(
    "require_once(__DIR__ . '/lib/setup.php');",
    debug_settings + "\nrequire_once(__DIR__ . '/lib/setup.php');"
)

# Write the updated config
with open(config_file, 'w') as f:
    f.write(content)

print("Config file updated successfully!")
PYTHON_EOF

# Run the Python script
echo "Step 3: Running Python script to edit config..."
python3 /tmp/fix_config.py
echo ""

# Verify the changes
echo "Step 4: Verifying changes..."
if grep -q '$CFG->debug' "$CONFIG_FILE"; then
    echo "Debug settings verified in config.php"
else
    echo "ERROR: Debug settings not found in config.php"
    exit 1
fi
echo ""

# Check for syntax errors
echo "Step 5: Checking PHP syntax..."
if php -l "$CONFIG_FILE" 2>&1 | grep -q "No syntax errors"; then
    echo "PHP syntax is valid"
else
    echo "WARNING: PHP syntax check failed"
    php -l "$CONFIG_FILE"
fi
echo ""

# Purge caches
echo "Step 6: Purging Moodle caches..."
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

