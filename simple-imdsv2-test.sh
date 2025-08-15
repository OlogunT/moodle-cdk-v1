#!/bin/bash
echo "=== Testing IMDSv2 Dynamic Discovery ==="

# Get IMDSv2 token
echo "Getting IMDSv2 token..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
if [ -n "$TOKEN" ]; then
  echo "✓ IMDSv2 token obtained"
else
  echo "✗ Failed to get IMDSv2 token"
  exit 1
fi

# Test region discovery
echo "Testing region discovery..."
REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region)
echo "Region: $REGION"

# Test instance ID discovery
echo "Testing instance ID discovery..."
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
echo "Instance ID: $INSTANCE_ID"

# Test stack name discovery
echo "Testing stack name discovery..."
STACK_NAME=$(aws ec2 describe-tags --region "$REGION" --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:cloudformation:stack-name" --query "Tags[0].Value" --output text 2>/dev/null)
if [ -z "$STACK_NAME" ] || [ "$STACK_NAME" = "None" ]; then
  echo "Warning: Could not determine stack name from tags, using default"
  STACK_NAME="MoodleCdkStack"
fi
echo "Stack name: $STACK_NAME"

# Test CloudFormation outputs
echo "Testing CloudFormation outputs..."
ALB_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey==\`MoodleUrl\`].OutputValue" --output text 2>/dev/null)
echo "ALB URL: $ALB_URL"

echo "=== Discovery Complete ==="
