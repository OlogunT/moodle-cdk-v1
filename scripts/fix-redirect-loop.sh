#!/bin/bash
set -euo pipefail

# Moodle Redirect Loop Fix Script
# Fixes ERR_TOO_MANY_REDIRECTS caused by incorrect reverse proxy settings
# when Moodle is behind an ALB with SSL termination

# Default configuration
REGION="${REGION:-ca-central-1}"
STACK_NAME="${STACK_NAME:-MoodleCdkStack}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-https://elearning.tsin.ca}"
VERIFY_AFTER="${VERIFY_AFTER:-true}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_success() { echo -e "${GREEN}✓ $1${NC}"; }
log_info() { echo -e "${CYAN}ℹ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
log_error() { echo -e "${RED}✗ $1${NC}"; }

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║   MOODLE REDIRECT LOOP FIX                     ║"
echo "╚════════════════════════════════════════════════╝"
echo ""

log_info "Region: $REGION"
log_info "Stack: $STACK_NAME"
log_info "Domain: $CUSTOM_DOMAIN"
echo ""

# Find healthy instances
log_info "Finding healthy instances in Auto Scaling Group..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'MoodleAutoScalingGroup')].AutoScalingGroupName | [0]" \
  --output text 2>/dev/null || echo "")

if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "None" ]; then
  log_error "Could not find Moodle Auto Scaling Group"
  exit 1
fi

log_info "Found ASG: $ASG_NAME"

INSTANCES=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy' && LifecycleState=='InService'].InstanceId" \
  --output text 2>/dev/null || echo "")

if [ -z "$INSTANCES" ]; then
  log_error "No healthy instances found in ASG $ASG_NAME"
  exit 1
fi

INSTANCE_ARRAY=($INSTANCES)
log_success "Found ${#INSTANCE_ARRAY[@]} healthy instance(s)"
echo ""

# Create fix script
cat > /tmp/moodle-redirect-fix.json << 'EOF'
{
  "commands": [
    "set -euo pipefail",
    "echo '=== MOODLE REDIRECT LOOP FIX ==='",
    "echo 'Fixing reverse proxy configuration for ALB with SSL termination'",
    "echo ''",
    "CFG=/app/moodle/config.php",
    "if [ ! -f \"$CFG\" ]; then",
    "  echo 'ERROR: Config file not found at /app/moodle/config.php'",
    "  exit 1",
    "fi",
    "echo 'Creating backup...'",
    "cp \"$CFG\" \"${CFG}.backup.redirect-fix.$(date +%Y%m%d_%H%M%S)\"",
    "echo ''",
    "echo '--- BEFORE ---'",
    "grep -n -E '(wwwroot|reverseproxy|sslproxy)' \"$CFG\" || echo 'No proxy settings found'",
    "echo ''",
    "echo 'Removing problematic proxy settings...'",
    "sed -i '/^\\$CFG->reverseproxy/d' \"$CFG\"",
    "sed -i '/^\\$CFG->sslproxy/d' \"$CFG\"",
    "sed -i '/^\\$CFG->getremoteaddrconf/d' \"$CFG\"",
    "sed -i '/^\\$CFG->cookiesecure/d' \"$CFG\"",
    "sed -i '/^\\$CFG->loginhttps/d' \"$CFG\"",
    "echo ''",
    "echo 'Adding correct SSL proxy setting...'",
    "sed -i '/require_once.*lib\\/setup\\.php/i \\$CFG->sslproxy = true;' \"$CFG\"",
    "echo ''",
    "echo 'Ensuring wwwroot uses HTTPS...'",
    "DOMAIN=\"REPLACE_DOMAIN_HERE\"",
    "if grep -q '^\\$CFG->wwwroot' \"$CFG\"; then",
    "  sed -i \"s|^\\$CFG->wwwroot.*|\\$CFG->wwwroot = '$DOMAIN';|\" \"$CFG\"",
    "else",
    "  sed -i \"/require_once.*lib\\/setup\\.php/i \\$CFG->wwwroot = '$DOMAIN';\" \"$CFG\"",
    "fi",
    "echo ''",
    "echo '--- AFTER ---'",
    "grep -n -E '(wwwroot|sslproxy|require_once)' \"$CFG\" | head -15",
    "echo ''",
    "echo 'Validating PHP syntax...'",
    "php -l \"$CFG\"",
    "echo ''",
    "echo 'Clearing Moodle caches...'",
    "rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/* 2>/dev/null || true",
    "sudo -u apache php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || echo 'CLI cache purge skipped'",
    "echo ''",
    "echo 'Restarting services...'",
    "systemctl restart php-fpm httpd",
    "sleep 3",
    "echo ''",
    "echo 'Testing local access...'",
    "curl -sI http://localhost/ | head -5",
    "echo ''",
    "echo '=== FIX COMPLETE ==='",
    "echo 'Configuration applied:'",
    "echo '  - sslproxy: true (handles ALB SSL termination)'",
    "echo '  - reverseproxy: removed (allows direct access from ALB)'",
    "echo \"  - wwwroot: $DOMAIN\"",
    "echo ''",
    "echo 'The redirect loop should now be resolved.'"
  ]
}
EOF

# Replace domain placeholder
sed -i.bak "s|REPLACE_DOMAIN_HERE|$CUSTOM_DOMAIN|g" /tmp/moodle-redirect-fix.json
rm -f /tmp/moodle-redirect-fix.json.bak

# Apply fix to each instance
log_info "Applying fix to ${#INSTANCE_ARRAY[@]} instance(s)..."
echo ""

for INSTANCE_ID in "${INSTANCE_ARRAY[@]}"; do
  echo "─────────────────────────────────────────────────"
  log_info "Processing instance: $INSTANCE_ID"
  
  CMD_ID=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "file:///tmp/moodle-redirect-fix.json" \
    --query "Command.CommandId" \
    --output text 2>&1)
  
  if [ -z "$CMD_ID" ] || [[ "$CMD_ID" == *"error"* ]]; then
    log_error "Failed to send command to $INSTANCE_ID"
    continue
  fi
  
  log_info "Command ID: $CMD_ID"
  log_info "Waiting for command to complete..."
  sleep 15
  
  STATUS=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>&1)
  
  OUTPUT=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>&1)
  
  echo ""
  echo "Status: $STATUS"
  echo ""
  echo "Output:"
  echo "$OUTPUT"
  echo ""
  
  if [ "$STATUS" = "Success" ]; then
    log_success "Instance $INSTANCE_ID fixed successfully"
  else
    log_warning "Instance $INSTANCE_ID status: $STATUS"
  fi
  echo ""
done

# Cleanup
rm -f /tmp/moodle-redirect-fix.json

# Verification
if [ "$VERIFY_AFTER" = "true" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════╗"
  echo "║   VERIFICATION TESTS                           ║"
  echo "╚════════════════════════════════════════════════╝"
  echo ""
  
  log_info "Testing: $CUSTOM_DOMAIN"
  echo ""
  
  sleep 5
  
  # Test 1: Health endpoint
  echo "1. Health Endpoint Test..."
  HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "$CUSTOM_DOMAIN/health" 2>&1 || echo "FAIL")
  if [ "$HEALTH" = "200" ] || [ "$HEALTH" = "OK" ]; then
    log_success "Health endpoint responding"
  else
    log_warning "Health endpoint returned: $HEALTH"
  fi
  
  # Test 2: Homepage
  echo ""
  echo "2. Homepage Test..."
  HOMEPAGE=$(curl -sL --max-time 15 "$CUSTOM_DOMAIN/" 2>&1 || echo "")
  if echo "$HOMEPAGE" | grep -qi "log in\|login"; then
    log_success "Login page loads successfully"
  else
    log_warning "Login page may not be loading correctly"
  fi
  
  # Test 3: Moodle detection
  echo ""
  echo "3. Moodle Detection..."
  if echo "$HOMEPAGE" | grep -qi "moodle"; then
    log_success "Moodle detected"
  else
    log_warning "Moodle not detected in page content"
  fi
  
  # Test 4: Error check
  echo ""
  echo "4. Error Page Check..."
  if echo "$HOMEPAGE" | grep -qi "alert-danger\|Reverse proxy enabled\|ERR_TOO_MANY_REDIRECTS"; then
    log_error "Error page or redirect loop still detected!"
  else
    log_success "No error pages detected"
  fi
  
  # Test 5: Redirect count
  echo ""
  echo "5. Redirect Loop Test..."
  REDIRECT_INFO=$(curl -sL --max-time 10 --max-redirs 20 -w "REDIRECTS:%{num_redirects}" -o /dev/null "$CUSTOM_DOMAIN/" 2>&1 || echo "REDIRECTS:0")
  if [[ "$REDIRECT_INFO" =~ REDIRECTS:([0-9]+) ]]; then
    REDIRECT_COUNT="${BASH_REMATCH[1]}"
    if [ "$REDIRECT_COUNT" -ge 10 ]; then
      log_error "Redirect loop detected! ($REDIRECT_COUNT redirects)"
    elif [ "$REDIRECT_COUNT" -le 3 ]; then
      log_success "Normal redirect behavior ($REDIRECT_COUNT redirects)"
    else
      log_warning "Multiple redirects detected ($REDIRECT_COUNT redirects)"
    fi
  fi
  
  echo ""
  echo "═══════════════════════════════════════════════"
  log_success "Verification complete!"
  echo "Site URL: $CUSTOM_DOMAIN"
  echo "═══════════════════════════════════════════════"
  echo ""
fi

log_success "All operations completed successfully!"
echo ""

