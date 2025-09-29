#!/bin/bash
# ============================================================================
# Diagnose SES Email Issues for Moodle
# ============================================================================
# This script performs comprehensive diagnostics for SES email configuration
# ============================================================================

set -euo pipefail

echo "=== SES EMAIL DIAGNOSTICS START ===" "$(date -u)"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# STEP 1: Environment Information
# ============================================================================
echo "--- Step 1: Environment Information ---"

TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || echo "ca-central-1")

INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id || echo "unknown")

AZ=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone || echo "unknown")

echo "Region: $REGION"
echo "Instance ID: $INSTANCE_ID"
echo "Availability Zone: $AZ"
echo ""

# ============================================================================
# STEP 2: Network Connectivity Tests
# ============================================================================
echo "--- Step 2: Network Connectivity Tests ---"

SES_ENDPOINT="email-smtp.$REGION.amazonaws.com"
echo "Testing connectivity to: $SES_ENDPOINT"
echo ""

# DNS Resolution
echo "2.1 DNS Resolution:"
if getent hosts "$SES_ENDPOINT" >/dev/null 2>&1; then
  IP=$(getent hosts "$SES_ENDPOINT" | awk '{print $1}' | head -1)
  echo -e "${GREEN}✓${NC} DNS resolution successful: $SES_ENDPOINT -> $IP"
else
  echo -e "${RED}✗${NC} DNS resolution failed for $SES_ENDPOINT"
fi
echo ""

# Port 587 (STARTTLS)
echo "2.2 Port 587 (STARTTLS) Connectivity:"
if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_ENDPOINT/587" 2>/dev/null; then
  echo -e "${GREEN}✓${NC} Port 587 is reachable"
else
  echo -e "${RED}✗${NC} Port 587 is NOT reachable"
  echo "  Possible causes:"
  echo "  - Security group egress rules blocking port 587"
  echo "  - Network ACL restrictions"
  echo "  - No NAT Gateway and no VPC endpoint"
fi
echo ""

# Port 465 (TLS)
echo "2.3 Port 465 (TLS) Connectivity:"
if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_ENDPOINT/465" 2>/dev/null; then
  echo -e "${GREEN}✓${NC} Port 465 is reachable"
else
  echo -e "${YELLOW}⚠${NC} Port 465 is NOT reachable (optional, 587 is preferred)"
fi
echo ""

# Port 25 (Should be avoided)
echo "2.4 Port 25 (Not recommended):"
if timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_ENDPOINT/25" 2>/dev/null; then
  echo -e "${YELLOW}⚠${NC} Port 25 is reachable (but EC2 throttles it - use 587 instead)"
else
  echo -e "${GREEN}✓${NC} Port 25 is blocked (expected - use port 587)"
fi
echo ""

# ============================================================================
# STEP 3: Security Group Analysis
# ============================================================================
echo "--- Step 3: Security Group Analysis ---"

SG_IDS=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
  --output text 2>/dev/null || echo "")

if [ -n "$SG_IDS" ]; then
  echo "Security Groups: $SG_IDS"
  echo ""
  
  for SG_ID in $SG_IDS; do
    echo "Analyzing Security Group: $SG_ID"
    
    # Check egress rules for SMTP ports
    EGRESS_587=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --region "$REGION" \
      --query "SecurityGroups[0].IpPermissionsEgress[?ToPort==\`587\`]" \
      --output json 2>/dev/null || echo "[]")
    
    if [ "$EGRESS_587" != "[]" ] && [ "$EGRESS_587" != "" ]; then
      echo -e "${GREEN}✓${NC} Egress rule for port 587 exists"
    else
      echo -e "${RED}✗${NC} No egress rule for port 587 found"
    fi
    
    EGRESS_465=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --region "$REGION" \
      --query "SecurityGroups[0].IpPermissionsEgress[?ToPort==\`465\`]" \
      --output json 2>/dev/null || echo "[]")
    
    if [ "$EGRESS_465" != "[]" ] && [ "$EGRESS_465" != "" ]; then
      echo -e "${GREEN}✓${NC} Egress rule for port 465 exists"
    else
      echo -e "${YELLOW}⚠${NC} No egress rule for port 465 found (optional)"
    fi
    
    # Check for allow-all egress
    EGRESS_ALL=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --region "$REGION" \
      --query "SecurityGroups[0].IpPermissionsEgress[?IpProtocol==\`-1\`]" \
      --output json 2>/dev/null || echo "[]")
    
    if [ "$EGRESS_ALL" != "[]" ] && [ "$EGRESS_ALL" != "" ]; then
      echo -e "${GREEN}✓${NC} Allow-all egress rule exists (covers SMTP ports)"
    fi
    echo ""
  done
else
  echo -e "${YELLOW}⚠${NC} Could not retrieve security group information"
  echo ""
fi

# ============================================================================
# STEP 4: VPC Endpoint Check
# ============================================================================
echo "--- Step 4: VPC Endpoint Check ---"

VPC_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].VpcId" \
  --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ]; then
  echo "VPC ID: $VPC_ID"
  
  VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=service-name,Values=com.amazonaws.$REGION.email-smtp" \
    --region "$REGION" \
    --query "VpcEndpoints[*].[VpcEndpointId,State,PrivateDnsEnabled]" \
    --output text 2>/dev/null || echo "")
  
  if [ -n "$VPC_ENDPOINTS" ]; then
    echo -e "${GREEN}✓${NC} SES VPC Endpoint found:"
    echo "$VPC_ENDPOINTS" | while read -r line; do
      echo "  $line"
    done
  else
    echo -e "${YELLOW}⚠${NC} No SES VPC Endpoint found"
    echo "  Using NAT Gateway for SES connectivity"
  fi
else
  echo -e "${YELLOW}⚠${NC} Could not retrieve VPC information"
fi
echo ""

# ============================================================================
# STEP 5: NAT Gateway Check
# ============================================================================
echo "--- Step 5: NAT Gateway Check ---"

SUBNET_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].SubnetId" \
  --output text 2>/dev/null || echo "")

if [ -n "$SUBNET_ID" ]; then
  echo "Subnet ID: $SUBNET_ID"
  
  # Check route table for NAT Gateway
  ROUTE_TABLE=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --region "$REGION" \
    --query "RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, 'nat-')]" \
    --output json 2>/dev/null || echo "[]")
  
  if [ "$ROUTE_TABLE" != "[]" ] && [ "$ROUTE_TABLE" != "" ]; then
    echo -e "${GREEN}✓${NC} NAT Gateway route found in route table"
  else
    echo -e "${YELLOW}⚠${NC} No NAT Gateway route found"
    echo "  Instance may be in isolated subnet or using VPC endpoint"
  fi
else
  echo -e "${YELLOW}⚠${NC} Could not retrieve subnet information"
fi
echo ""

# ============================================================================
# STEP 6: Moodle Configuration Check
# ============================================================================
echo "--- Step 6: Moodle Configuration Check ---"

CFG=/app/moodle/config.php

if [ -f "$CFG" ]; then
  echo -e "${GREEN}✓${NC} config.php found"
  
  # Extract database connection
  DB_HOST=$(grep -E '^\s*\$CFG->dbhost' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
  DB_NAME=$(grep -E '^\s*\$CFG->dbname' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
  DB_USER=$(grep -E '^\s*\$CFG->dbuser' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
  DB_PASS=$(grep -E '^\s*\$CFG->dbpass' "$CFG" | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/" || echo "")
  
  if [ -n "$DB_HOST" ]; then
    echo "Database Host: $DB_HOST"
    
    # Check SMTP configuration in database
    echo ""
    echo "Current SMTP Configuration:"
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
      "SELECT name, 
              CASE 
                WHEN name = 'smtppass' THEN '***REDACTED***'
                ELSE value 
              END as value 
       FROM mdl_config 
       WHERE name IN ('smtphosts', 'smtpuser', 'smtppass', 'smtpsecure', 'smtpport', 
                      'noreplyaddress', 'supportemail') 
       ORDER BY name;" 2>/dev/null || echo -e "${YELLOW}⚠${NC} Could not query database"
    
    # Check email queue
    echo ""
    echo "Email Queue Status:"
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
      "SELECT 
         COUNT(*) as total_emails,
         SUM(CASE WHEN status = 0 THEN 1 ELSE 0 END) as pending,
         SUM(CASE WHEN status = 1 THEN 1 ELSE 0 END) as sent,
         SUM(CASE WHEN status = 2 THEN 1 ELSE 0 END) as failed
       FROM mdl_email_queue;" 2>/dev/null || echo -e "${YELLOW}⚠${NC} Could not query email queue"
  else
    echo -e "${RED}✗${NC} Could not extract database connection details"
  fi
else
  echo -e "${RED}✗${NC} config.php not found at $CFG"
fi
echo ""

# ============================================================================
# STEP 7: IAM Permissions Check
# ============================================================================
echo "--- Step 7: IAM Permissions Check ---"

# Try to call SES API to verify permissions
if aws ses get-send-quota --region "$REGION" >/dev/null 2>&1; then
  echo -e "${GREEN}✓${NC} IAM permissions for SES API verified"
  
  QUOTA=$(aws ses get-send-quota --region "$REGION" 2>/dev/null || echo "{}")
  echo "SES Sending Quota:"
  echo "$QUOTA" | jq -r 'to_entries | .[] | "  \(.key): \(.value)"' 2>/dev/null || echo "$QUOTA"
else
  echo -e "${YELLOW}⚠${NC} Could not verify SES API permissions"
fi
echo ""

# ============================================================================
# STEP 8: Summary and Recommendations
# ============================================================================
echo "=== DIAGNOSTIC SUMMARY ===" 
echo ""

# Determine overall status
ISSUES=0

# Check critical issues
if ! timeout 10 bash -c "cat < /dev/null > /dev/tcp/$SES_ENDPOINT/587" 2>/dev/null; then
  echo -e "${RED}✗ CRITICAL:${NC} Port 587 is not reachable"
  ISSUES=$((ISSUES + 1))
fi

if ! getent hosts "$SES_ENDPOINT" >/dev/null 2>&1; then
  echo -e "${RED}✗ CRITICAL:${NC} DNS resolution failed"
  ISSUES=$((ISSUES + 1))
fi

if [ $ISSUES -eq 0 ]; then
  echo -e "${GREEN}✓ All critical checks passed${NC}"
  echo ""
  echo "Recommendations:"
  echo "1. Verify SES SMTP credentials are configured in Moodle"
  echo "2. Verify email addresses in SES Console"
  echo "3. Send a test email to verify end-to-end functionality"
else
  echo -e "${RED}Found $ISSUES critical issue(s)${NC}"
  echo ""
  echo "Recommended Actions:"
  echo "1. Verify security group egress rules allow port 587"
  echo "2. Check if VPC endpoint or NAT Gateway is configured"
  echo "3. Review network ACLs for subnet restrictions"
  echo "4. Redeploy CDK stack with SES enhancements"
fi

echo ""
echo "=== SES EMAIL DIAGNOSTICS END ===" "$(date -u)"

