#!/bin/bash
# Check Moodle SMTP configuration

echo "=== Checking Moodle SMTP Configuration ==="
echo ""

# Get DB credentials from config.php
DB_HOST=$(grep "dbhost" /app/moodle/config.php | cut -d"'" -f2)
DB_USER=$(grep "dbuser" /app/moodle/config.php | cut -d"'" -f2)
DB_PASS=$(grep "dbpass" /app/moodle/config.php | cut -d"'" -f2)
DB_NAME=$(grep "dbname" /app/moodle/config.php | cut -d"'" -f2)

echo "Database: $DB_NAME @ $DB_HOST"
echo ""

echo "SMTP Configuration in Database:"
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT name, value FROM mdl_config WHERE name LIKE 'smtp%' OR name = 'noreplyaddress';"

echo ""
echo "Checking config.php for SMTP settings:"
grep -i smtp /app/moodle/config.php || echo "No SMTP settings in config.php (this is normal - settings are in database)"

