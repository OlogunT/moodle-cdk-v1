#!/bin/bash
#
# Restore Training Moodle Data Files from Backup
#
# This script downloads the moodledata backup from S3 and restores it to EFS.
# It should be run on an EC2 instance with EFS mounted at /data.
#
# Usage:
#   ./restore-training-moodledata.sh [moodledata-backup-file.tar.gz]
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-TrainingMoodleCdkStack}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="${S3_BUCKET:-training-moodle-backups-${ACCOUNT_ID}-${REGION}}"
DATA_DIR="${DATA_DIR:-/data}"
MOODLEDATA_DIR="${MOODLEDATA_DIR:-$DATA_DIR/moodledata}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Training Moodle Data Files Restoration Script             ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Step 1: Verify EFS Mount
# ============================================================================

echo -e "${YELLOW}--- Step 1: Verifying EFS Mount ---${NC}"
echo ""

# Check if data directory exists
if [ ! -d "$DATA_DIR" ]; then
  echo -e "${RED}✗ Data directory does not exist: $DATA_DIR${NC}"
  exit 1
fi

# Check if it's a mount point
if mountpoint -q "$DATA_DIR"; then
  echo -e "${GREEN}✓ $DATA_DIR is a mount point${NC}"
else
  echo -e "${YELLOW}⚠ $DATA_DIR is not a mount point${NC}"
  echo -e "${CYAN}Checking if it's an EFS mount...${NC}"
fi

# Check available space
AVAILABLE_SPACE=$(df -h "$DATA_DIR" | tail -1 | awk '{print $4}')
echo -e "${GREEN}✓ Available space: $AVAILABLE_SPACE${NC}"

# Check write permissions
if [ -w "$DATA_DIR" ]; then
  echo -e "${GREEN}✓ Write permissions OK${NC}"
else
  echo -e "${RED}✗ No write permissions on $DATA_DIR${NC}"
  echo -e "${YELLOW}  Try running with sudo or check permissions${NC}"
  exit 1
fi

echo ""

# ============================================================================
# Step 2: Download Moodledata Backup from S3
# ============================================================================

echo -e "${YELLOW}--- Step 2: Downloading Moodledata Backup ---${NC}"
echo ""

# List available backups
echo -e "${CYAN}Available moodledata backups in S3:${NC}"
aws s3 ls "s3://$S3_BUCKET/moodledata/" --region "$REGION" || {
  echo -e "${RED}✗ Could not list S3 bucket contents${NC}"
  echo -e "${YELLOW}  Bucket: s3://$S3_BUCKET/moodledata/${NC}"
  exit 1
}
echo ""

# Get backup file from parameter or prompt
if [ $# -eq 0 ]; then
  echo -e "${CYAN}Enter the moodledata backup filename to restore:${NC}"
  read -r BACKUP_FILE
else
  BACKUP_FILE="$1"
fi

echo -e "${CYAN}Downloading: $BACKUP_FILE${NC}"
echo -e "${YELLOW}This may take several minutes depending on file size...${NC}"

# Download to /tmp
TMP_BACKUP="/tmp/$BACKUP_FILE"
aws s3 cp "s3://$S3_BUCKET/moodledata/$BACKUP_FILE" "$TMP_BACKUP" --region "$REGION"

if [ ! -f "$TMP_BACKUP" ]; then
  echo -e "${RED}✗ Download failed${NC}"
  exit 1
fi

BACKUP_SIZE=$(du -h "$TMP_BACKUP" | cut -f1)
echo -e "${GREEN}✓ Downloaded: $BACKUP_FILE ($BACKUP_SIZE)${NC}"
echo ""

# ============================================================================
# Step 3: Backup Existing Moodledata (if exists)
# ============================================================================

echo -e "${YELLOW}--- Step 3: Checking Existing Moodledata ---${NC}"
echo ""

if [ -d "$MOODLEDATA_DIR" ]; then
  EXISTING_SIZE=$(du -sh "$MOODLEDATA_DIR" | cut -f1)
  echo -e "${YELLOW}⚠ Existing moodledata directory found: $MOODLEDATA_DIR ($EXISTING_SIZE)${NC}"
  echo -e "${CYAN}Do you want to backup existing data before restoring? (y/n):${NC}"
  read -r BACKUP_EXISTING
  
  if [ "$BACKUP_EXISTING" == "y" ]; then
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_NAME="moodledata_backup_$BACKUP_TIMESTAMP"
    
    echo -e "${CYAN}Creating backup: $DATA_DIR/$BACKUP_NAME${NC}"
    mv "$MOODLEDATA_DIR" "$DATA_DIR/$BACKUP_NAME"
    echo -e "${GREEN}✓ Existing data backed up to: $DATA_DIR/$BACKUP_NAME${NC}"
  else
    echo -e "${CYAN}Do you want to remove existing moodledata? (y/n):${NC}"
    read -r REMOVE_EXISTING
    
    if [ "$REMOVE_EXISTING" == "y" ]; then
      echo -e "${YELLOW}Removing existing moodledata...${NC}"
      rm -rf "$MOODLEDATA_DIR"
      echo -e "${GREEN}✓ Existing data removed${NC}"
    else
      echo -e "${RED}✗ Cannot proceed with existing data in place${NC}"
      exit 1
    fi
  fi
else
  echo -e "${GREEN}✓ No existing moodledata directory${NC}"
fi

# Create moodledata directory
mkdir -p "$MOODLEDATA_DIR"
echo -e "${GREEN}✓ Created directory: $MOODLEDATA_DIR${NC}"

echo ""

# ============================================================================
# Step 4: Extract Moodledata Backup
# ============================================================================

echo -e "${YELLOW}--- Step 4: Extracting Moodledata Backup ---${NC}"
echo ""

echo -e "${CYAN}Extracting backup to $MOODLEDATA_DIR...${NC}"
echo -e "${YELLOW}This may take several minutes depending on file size...${NC}"
echo ""

START_TIME=$(date +%s)

# Determine extraction method based on file extension
if [[ "$BACKUP_FILE" == *.tar.gz ]] || [[ "$BACKUP_FILE" == *.tgz ]]; then
  echo -e "${CYAN}Extracting tar.gz archive...${NC}"
  tar -xzf "$TMP_BACKUP" -C "$DATA_DIR"
  EXTRACT_EXIT_CODE=$?
  
elif [[ "$BACKUP_FILE" == *.tar ]]; then
  echo -e "${CYAN}Extracting tar archive...${NC}"
  tar -xf "$TMP_BACKUP" -C "$DATA_DIR"
  EXTRACT_EXIT_CODE=$?
  
elif [[ "$BACKUP_FILE" == *.zip ]]; then
  echo -e "${CYAN}Extracting ZIP archive...${NC}"
  unzip -q "$TMP_BACKUP" -d "$DATA_DIR"
  EXTRACT_EXIT_CODE=$?
  
else
  echo -e "${RED}✗ Unsupported archive format: $BACKUP_FILE${NC}"
  echo -e "${YELLOW}  Supported formats: .tar.gz, .tgz, .tar, .zip${NC}"
  exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $EXTRACT_EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}✓ Extraction completed successfully${NC}"
  echo -e "  Duration: ${CYAN}${DURATION} seconds${NC}"
else
  echo -e "${RED}✗ Extraction failed${NC}"
  exit 1
fi

echo ""

# ============================================================================
# Step 5: Set Permissions
# ============================================================================

echo -e "${YELLOW}--- Step 5: Setting Permissions ---${NC}"
echo ""

echo -e "${CYAN}Setting ownership to apache:apache...${NC}"
chown -R apache:apache "$MOODLEDATA_DIR"

echo -e "${CYAN}Setting directory permissions to 755...${NC}"
find "$MOODLEDATA_DIR" -type d -exec chmod 755 {} \;

echo -e "${CYAN}Setting file permissions to 644...${NC}"
find "$MOODLEDATA_DIR" -type f -exec chmod 644 {} \;

echo -e "${GREEN}✓ Permissions set${NC}"

echo ""

# ============================================================================
# Step 6: Verify Restoration
# ============================================================================

echo -e "${YELLOW}--- Step 6: Verifying Restoration ---${NC}"
echo ""

# Check directory structure
EXPECTED_DIRS=("cache" "filedir" "lang" "localcache" "sessions" "temp" "trashdir")
MISSING_DIRS=()

for dir in "${EXPECTED_DIRS[@]}"; do
  if [ -d "$MOODLEDATA_DIR/$dir" ]; then
    echo -e "${GREEN}✓ Found: $dir${NC}"
  else
    echo -e "${YELLOW}⚠ Missing: $dir${NC}"
    MISSING_DIRS+=("$dir")
  fi
done

# Create missing directories
if [ ${#MISSING_DIRS[@]} -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}Creating missing directories...${NC}"
  for dir in "${MISSING_DIRS[@]}"; do
    mkdir -p "$MOODLEDATA_DIR/$dir"
    chown apache:apache "$MOODLEDATA_DIR/$dir"
    chmod 755 "$MOODLEDATA_DIR/$dir"
    echo -e "${GREEN}✓ Created: $dir${NC}"
  done
fi

echo ""

# Get total size
TOTAL_SIZE=$(du -sh "$MOODLEDATA_DIR" | cut -f1)
echo -e "${GREEN}✓ Total moodledata size: $TOTAL_SIZE${NC}"

# Count files
FILE_COUNT=$(find "$MOODLEDATA_DIR" -type f | wc -l)
echo -e "${GREEN}✓ Total files: $FILE_COUNT${NC}"

# Count directories
DIR_COUNT=$(find "$MOODLEDATA_DIR" -type d | wc -l)
echo -e "${GREEN}✓ Total directories: $DIR_COUNT${NC}"

echo ""

# ============================================================================
# Step 7: Cleanup
# ============================================================================

echo -e "${YELLOW}--- Step 7: Cleanup ---${NC}"
echo ""

echo -e "${CYAN}Removing temporary backup file...${NC}"
rm -f "$TMP_BACKUP"
echo -e "${GREEN}✓ Cleanup complete${NC}"

echo ""

# ============================================================================
# Summary
# ============================================================================

echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Moodledata Restoration Complete!                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}Moodledata Statistics:${NC}"
echo -e "  Location:    ${GREEN}$MOODLEDATA_DIR${NC}"
echo -e "  Total Size:  ${GREEN}$TOTAL_SIZE${NC}"
echo -e "  Files:       ${GREEN}$FILE_COUNT${NC}"
echo -e "  Directories: ${GREEN}$DIR_COUNT${NC}"
echo ""

echo -e "${CYAN}Next Steps:${NC}"
echo -e "  1. Verify database has been restored"
echo -e "  2. Deploy Moodle code to /app/moodle"
echo -e "  3. Create config.php with dataroot='/data/moodledata'"
echo -e "  4. Run Moodle upgrade: php admin/cli/upgrade.php"
echo ""

echo -e "${YELLOW}For detailed instructions, see: TRAINING-MOODLE-MIGRATION-PLAN.md${NC}"
echo ""

