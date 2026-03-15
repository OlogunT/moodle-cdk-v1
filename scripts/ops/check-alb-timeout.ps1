# Check ALB timeout and increase it if needed
$albArn = aws --profile tsin-account --region ca-central-1 elbv2 describe-load-balancers `
    --query 'LoadBalancers[0].LoadBalancerArn' --output text

Write-Host "ALB ARN: $albArn"

# Get current idle timeout
$attrs = aws --profile tsin-account --region ca-central-1 elbv2 describe-load-balancer-attributes `
    --load-balancer-arn $albArn `
    --query 'Attributes[?Key==`idle_timeout.timeout_seconds`].Value' --output text

Write-Host "Current idle timeout: ${attrs}s"

# Increase to 120 seconds
Write-Host "Setting idle timeout to 120 seconds..."
aws --profile tsin-account --region ca-central-1 elbv2 modify-load-balancer-attributes `
    --load-balancer-arn $albArn `
    --attributes "Key=idle_timeout.timeout_seconds,Value=120" `
    --output json

Write-Host "Done. New timeout should be 120 seconds."

