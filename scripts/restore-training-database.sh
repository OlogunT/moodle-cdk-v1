#!/bin/bash
#
# Restore Training Moodle Database from Backup
#
# This script downloads the database backup from S3 and restores it to RDS.
# It should be run on an EC2 instance with access to the RDS database.
#
# Usage:
#   ./restore-training-database.sh [database-backup-file.sql.gz]
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-TrainingMoodleCdkStack}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="${S3_BUCKET:-training-moodle-backups-${ACCOUNT_ID}-${REGION}}"
DB_NAME="${DB_NAME:-moodle}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Training Moodle Database Restoration Script               ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Step 1: Get Database Credentials
# ============================================================================

echo -e "${YELLOW}--- Step 1: Retrieving Database Credentials ---${NC}"
echo ""

# Get secret ARN from CloudFormation
SECRET_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DatabaseSecretArn'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -z "$SECRET_ARN" ]; then
  echo -e "${RED}✗ Could not find database secret ARN in stack outputs${NC}"
  echo -e "${YELLOW}  Trying alternative method...${NC}"
  
  # Try to find secret by name pattern
  SECRET_ARN=$(aws secretsmanager list-secrets \
    --region "$REGION" \
    --query "SecretList[?contains(Name, 'TrainingMoodle')].ARN | [0]" \
    --output text)
fi

if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" == "None" ]; then
  echo -e "${RED}✗ Could not find database secret${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Found database secret: $SECRET_ARN${NC}"

# Get credentials from Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --region "$REGION" \
  --query SecretString \
  --output text)

DB_HOST=$(echo "$SECRET_JSON" | jq -r .host)
DB_USER=$(echo "$SECRET_JSON" | jq -r .username)
DB_PASS=$(echo "$SECRET_JSON" | jq -r .password)

echo -e "${GREEN}✓ Database credentials retrieved${NC}"
echo -e "  Host: ${CYAN}$DB_HOST${NC}"
echo -e "  User: ${CYAN}$DB_USER${NC}"
echo -e "  Database: ${CYAN}$DB_NAME${NC}"
echo ""

# ============================================================================
# Step 2: Download Database Backup from S3
# ============================================================================

echo -e "${YELLOW}--- Step 2: Downloading Database Backup ---${NC}"
echo ""

# List available backups
echo -e "${CYAN}Available database backups in S3:${NC}"
aws s3 ls "s3://$S3_BUCKET/database/" --region "$REGION" || {
  echo -e "${RED}✗ Could not list S3 bucket contents${NC}"
  echo -e "${YELLOW}  Bucket: s3://$S3_BUCKET/database/${NC}"
  exit 1
}
echo ""

# Get backup file from parameter or prompt
if [ $# -eq 0 ]; then
  echo -e "${CYAN}Enter the database backup filename to restore:${NC}"
  read -r BACKUP_FILE
else
  BACKUP_FILE="$1"
fi

echo -e "${CYAN}Downloading: $BACKUP_FILE${NC}"

# Download to /tmp
TMP_BACKUP="/tmp/$BACKUP_FILE"
aws s3 cp "s3://$S3_BUCKET/database/$BACKUP_FILE" "$TMP_BACKUP" --region "$REGION"

if [ ! -f "$TMP_BACKUP" ]; then
  echo -e "${RED}✗ Download failed${NC}"
  exit 1
fi

BACKUP_SIZE=$(du -h "$TMP_BACKUP" | cut -f1)
echo -e "${GREEN}✓ Downloaded: $BACKUP_FILE ($BACKUP_SIZE)${NC}"
echo ""

# ============================================================================
# Step 3: Extract Backup if Compressed
# ============================================================================

echo -e "${YELLOW}--- Step 3: Preparing Backup File ---${NC}"
echo ""

SQL_FILE="$TMP_BACKUP"

# Check if file is compressed
if [[ "$BACKUP_FILE" == *.gz ]]; then
  echo -e "${CYAN}Extracting compressed backup...${NC}"
  gunzip -f "$TMP_BACKUP"
  SQL_FILE="${TMP_BACKUP%.gz}"
  
  if [ ! -f "$SQL_FILE" ]; then
    echo -e "${RED}✗ Extraction failed${NC}"
    exit 1
  fi
  
  SQL_SIZE=$(du -h "$SQL_FILE" | cut -f1)
  echo -e "${GREEN}✓ Extracted: $SQL_SIZE${NC}"
elif [[ "$BACKUP_FILE" == *.zip ]]; then
  echo -e "${CYAN}Extracting ZIP archive...${NC}"
  unzip -o "$TMP_BACKUP" -d /tmp/
  
  # Find the SQL file in the extracted contents
  SQL_FILE=$(find /tmp -name "*.sql" -type f | head -1)
  
  if [ -z "$SQL_FILE" ]; then
    echo -e "${RED}✗ No SQL file found in ZIP archive${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}✓ Extracted: $SQL_FILE${NC}"
else
  echo -e "${GREEN}✓ Backup file is not compressed${NC}"
fi

echo ""

# ============================================================================
# Step 4: Test Database Connection
# ============================================================================

echo -e "${YELLOW}--- Step 4: Testing Database Connection ---${NC}"
echo ""

# Test connection
if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" &>/dev/null; then
  echo -e "${GREEN}✓ Database connection successful${NC}"
else
  echo -e "${RED}✗ Database connection failed${NC}"
  echo -e "${YELLOW}  Please check security groups and network connectivity${NC}"
  exit 1
fi

# Check if database exists
DB_EXISTS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
  -e "SHOW DATABASES LIKE '$DB_NAME';" | grep -c "$DB_NAME" || echo "0")

if [ "$DB_EXISTS" -eq 0 ]; then
  echo -e "${YELLOW}⚠ Database '$DB_NAME' does not exist, creating...${NC}"
  mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
    -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  echo -e "${GREEN}✓ Database created${NC}"
else
  echo -e "${YELLOW}⚠ Database '$DB_NAME' already exists${NC}"
  echo -e "${CYAN}Do you want to drop and recreate it? (y/n):${NC}"
  read -r CONFIRM
  
  if [ "$CONFIRM" == "y" ]; then
    echo -e "${YELLOW}Dropping existing database...${NC}"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE $DB_NAME;"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
      -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    echo -e "${GREEN}✓ Database recreated${NC}"
  else
    echo -e "${YELLOW}⚠ Importing into existing database (may cause conflicts)${NC}"
  fi
fi

echo ""

# ============================================================================
# Step 5: Import Database Backup
# ============================================================================

echo -e "${YELLOW}--- Step 5: Importing Database Backup ---${NC}"
echo ""

echo -e "${CYAN}Starting database import...${NC}"
echo -e "${YELLOW}This may take several minutes depending on database size...${NC}"
echo ""

# Import with progress indicator
START_TIME=$(date +%s)

mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE" 2>&1 | \
  while IFS= read -r line; do
    echo -e "${YELLOW}  $line${NC}"
  done

IMPORT_EXIT_CODE=${PIPESTATUS[0]}

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $IMPORT_EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}✓ Database import completed successfully${NC}"
  echo -e "  Duration: ${CYAN}${DURATION} seconds${NC}"
else
  echo -e "${RED}✗ Database import failed${NC}"
  exit 1
fi

echo ""

# ============================================================================
# Step 6: Verify Import
# ============================================================================

echo -e "${YELLOW}--- Step 6: Verifying Import ---${NC}"
echo ""

# Count tables
TABLE_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
  -e "SHOW TABLES;" | wc -l)
TABLE_COUNT=$((TABLE_COUNT - 1)) # Subtract header row

echo -e "${GREEN}✓ Tables imported: $TABLE_COUNT${NC}"

# Count users
USER_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
  -e "SELECT COUNT(*) FROM mdl_user;" | tail -1)

echo -e "${GREEN}✓ Users in database: $USER_COUNT${NC}"

# Count courses
COURSE_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
  -e "SELECT COUNT(*) FROM mdl_course;" | tail -1)

echo -e "${GREEN}✓ Courses in database: $COURSE_COUNT${NC}"

# Get site name
SITE_NAME=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
  -e "SELECT value FROM mdl_config WHERE name='fullname';" | tail -1)

echo -e "${GREEN}✓ Site name: $SITE_NAME${NC}"

echo ""

# ============================================================================
# Step 7: Cleanup
# ============================================================================

echo -e "${YELLOW}--- Step 7: Cleanup ---${NC}"
echo ""

echo -e "${CYAN}Removing temporary files...${NC}"
rm -f "$TMP_BACKUP" "$SQL_FILE"
echo -e "${GREEN}✓ Cleanup complete${NC}"

echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Database Restoration Complete!                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}Database Statistics:${NC}"
echo -e "  Tables:  ${GREEN}$TABLE_COUNT${NC}"
echo -e "  Users:   ${GREEN}$USER_COUNT${NC}"
echo -e "  Courses: ${GREEN}$COURSE_COUNT${NC}"
echo -e "  Site:    ${GREEN}$SITE_NAME${NC}"
echo ""

echo -e "${CYAN}Next Steps:${NC}"
echo -e "  1. Restore moodledata files (run restore-training-moodledata.sh)"
echo -e "  2. Deploy Moodle code to /app/moodle"
echo -e "  3. Create config.php with correct settings"
echo -e "  4. Run Moodle upgrade: php admin/cli/upgrade.php"
echo ""

echo -e "${YELLOW}For detailed instructions, see: TRAINING-MOODLE-MIGRATION-PLAN.md${NC}"
echo ""

