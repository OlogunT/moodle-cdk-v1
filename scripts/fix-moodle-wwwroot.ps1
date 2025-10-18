param(
  [string]$Region = "ca-central-1",
  [string]$CustomDomain = "https://elearning.tsin.ca"
)

$ErrorActionPreference = 'Stop'

Write-Host "=== FIXING MOODLE WWWROOT TO USE CUSTOM DOMAIN ===" -ForegroundColor Cyan
Write-Host "Target URL: $CustomDomain"
Write-Host ""

# Get all instances in the ASG
$instances = aws autoscaling describe-auto-scaling-groups `
  --region $Region `
  --auto-scaling-group-names MoodleCdkStack-MoodleAutoScalingGroupASG71555747-NHdD742pwfZu `
  --query "AutoScalingGroups[0].Instances[?HealthStatus=='Healthy'].InstanceId" `
  --output text

if (-not $instances) {
  Write-Host "No healthy instances found" -ForegroundColor Red
  exit 1
}

$instanceList = $instances.Split("`t")
Write-Host "Found $($instanceList.Count) healthy instance(s): $($instanceList -join ', ')"
Write-Host ""

foreach ($instanceId in $instanceList) {
  Write-Host "Updating instance: $instanceId" -ForegroundColor Yellow
  
  # Create JSON parameters file
  $params = @{
    commands = @(
      "echo '=== FIXING MOODLE WWWROOT ==='",
      "if [ ! -f /app/moodle/config.php ]; then echo 'Config not found'; exit 1; fi",
      "echo 'Current wwwroot:'",
      "grep 'wwwroot' /app/moodle/config.php | head -1",
      "echo ''",
      "echo 'Creating backup...'",
      "cp /app/moodle/config.php /app/moodle/config.php.backup.wwwroot.`$(date +%s)",
      "echo 'Updating wwwroot to: $CustomDomain'",
      "sed -i `"s|^\`$CFG->wwwroot.*|\`$CFG->wwwroot = '$CustomDomain';|`" /app/moodle/config.php",
      "echo 'New wwwroot:'",
      "grep 'wwwroot' /app/moodle/config.php | head -1",
      "echo ''",
      "echo 'Checking syntax...'",
      "php -l /app/moodle/config.php",
      "echo ''",
      "echo 'Updating database...'",
      "DB_SECRET=`$(aws secretsmanager list-secrets --region $Region --query `"SecretList[?contains(Name, 'MoodleDbSecret')].ARN | [0]`" --output text)",
      "DB_CREDS=`$(aws secretsmanager get-secret-value --region $Region --secret-id `$DB_SECRET --query SecretString --output text)",
      "DB_HOST=`$(echo `$DB_CREDS | jq -r .host)",
      "DB_USER=`$(echo `$DB_CREDS | jq -r .username)",
      "DB_PASS=`$(echo `$DB_CREDS | jq -r .password)",
      "DB_NAME=`$(echo `$DB_CREDS | jq -r .dbname)",
      "mariadb -h `$DB_HOST -u `$DB_USER -p`$DB_PASS -D `$DB_NAME -e `"UPDATE mdl_config SET value='$CustomDomain' WHERE name='wwwroot';`" && echo '✓ Database updated' || echo '⚠ Database update failed'",
      "echo ''",
      "echo 'Clearing Moodle caches...'",
      "rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/* 2>/dev/null || true",
      "sudo -u apache php /app/moodle/admin/cli/purge_caches.php 2>/dev/null || true",
      "echo ''",
      "echo 'Restarting services...'",
      "systemctl restart php-fpm httpd",
      "echo '✓ Services restarted'",
      "echo ''",
      "echo '=== WWWROOT FIX COMPLETE ==='"
    )
  } | ConvertTo-Json -Compress

  $tmpFile = New-TemporaryFile
  [System.IO.File]::WriteAllText($tmpFile.FullName, $params, [System.Text.UTF8Encoding]::new($false))

  try {
    $cmdId = aws ssm send-command `
      --region $Region `
      --instance-ids $instanceId `
      --document-name AWS-RunShellScript `
      --timeout-seconds 300 `
      --parameters "file://$($tmpFile.FullName)" `
      --query "Command.CommandId" `
      --output text
    
    Write-Host "  Command sent: $cmdId"
    Write-Host "  Waiting for completion..."
    
    Start-Sleep -Seconds 10
    
    $output = aws ssm get-command-invocation `
      --region $Region `
      --command-id $cmdId `
      --instance-id $instanceId `
      --query "StandardOutputContent" `
      --output text
    
    Write-Host $output
    Write-Host ""
    
  } finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "=== TESTING ENDPOINTS ===" -ForegroundColor Green
Start-Sleep -Seconds 5
curl -I https://elearning.tsin.ca/ 2>&1 | Select-String "HTTP|Location"

