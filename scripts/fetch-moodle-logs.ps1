param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack",
  [int]$TailLines = 200
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-MoodleInstanceIds {
  param([string]$Region)
  # Prefer instances registered in the Moodle target group created by CDK (name starts with 'Moodle-Moodl-')
  $tgArn = aws elbv2 describe-target-groups --region $Region --query "TargetGroups[?starts_with(TargetGroupName, 'Moodle-Moodl-')].TargetGroupArn | [0]" --output text 2>$null
  if (-not $tgArn -or $tgArn -eq 'None') { return @() }
  $ids = aws elbv2 describe-target-health --region $Region --target-group-arn $tgArn --query "TargetHealthDescriptions[].Target.Id" --output text 2>$null
  if (-not $ids) { return @() }
  return $ids -split "`t" | Where-Object { $_ -and $_ -ne 'None' }
}

function Invoke-LogSSM {
  param([string]$InstanceId,[string]$Region,[int]$TailLines)
  Write-Host ("Collecting logs from instance {0}" -f $InstanceId)
  $cmds = @(
    "set +e",
    "echo '=== HOST ==='",
    "hostname; uptime; date",
    "echo '=== SERVICES ==='",
    "systemctl is-active httpd || true; systemctl is-active php-fpm || true",
    "echo '=== PORTS ==='",
    "ss -ltnp | head -n 50 || true",
    "echo '=== DISK/MEM ==='",
    "df -h | sed -n '1,50p' || true; free -m || true",
    "echo '=== APACHE ERROR (tail -n $TailLines) ==='",
    "[ -f /var/log/httpd/error_log ] && tail -n $TailLines /var/log/httpd/error_log || echo 'missing /var/log/httpd/error_log'",
    "echo '=== APACHE MOODLE ERROR (tail -n $TailLines) ==='",
    "[ -f /var/log/httpd/moodle_error.log ] && tail -n $TailLines /var/log/httpd/moodle_error.log || echo 'missing /var/log/httpd/moodle_error.log'",
    "echo '=== PHP-FPM ERROR (tail -n $TailLines) ==='",
    "[ -f /var/log/php-fpm/www-error.log ] && tail -n $TailLines /var/log/php-fpm/www-error.log || echo 'missing /var/log/php-fpm/www-error.log'",
    "echo '=== PHP-FPM SLOW (tail -n $TailLines) ==='",
    "[ -f /var/log/php-fpm/www-slow.log ] && tail -n $TailLines /var/log/php-fpm/www-slow.log || echo 'missing /var/log/php-fpm/www-slow.log'",
    "echo '=== USER-DATA LOG (tail -n $TailLines) ==='",
    "[ -f /var/log/user-data.log ] && tail -n $TailLines /var/log/user-data.log || echo 'missing /var/log/user-data.log'",
    "echo '=== BOOTSTRAP LOG (tail -n $TailLines) ==='",
    "[ -f /var/log/bootstrap-moodle.log ] && tail -n $TailLines /var/log/bootstrap-moodle.log || echo 'missing /var/log/bootstrap-moodle.log'",
    "echo '=== INSTALLER LOG (tail -n $TailLines) ==='",
    "[ -f /var/log/moodle-install.log ] && tail -n $TailLines /var/log/moodle-install.log || echo 'missing /var/log/moodle-install.log'",
    "echo '=== CONFIG/FILES CHECK ==='",
    "ls -l /etc/httpd/conf.d/moodle.conf 2>/dev/null || echo 'missing /etc/httpd/conf.d/moodle.conf'",
    "ls -l /etc/php-fpm.d/www.conf 2>/dev/null || echo 'missing /etc/php-fpm.d/www.conf'",
    "ls -l /etc/php.d/99-moodle.ini 2>/dev/null || echo 'missing /etc/php.d/99-moodle.ini'",
    "ls -l /app/moodle/config.php 2>/dev/null || echo 'missing /app/moodle/config.php'",
    "echo '--- config.php (head) ---'; [ -f /app/moodle/config.php ] && head -n 40 /app/moodle/config.php || true",
    "echo '=== HEALTH CHECK (localhost) ==='",
    "curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://localhost/health || true",
    "echo '=== HOME (localhost) ==='",
    "curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://localhost/ || true"
  )
  $paramObj = [ordered]@{ commands = $cmds }
  $tmp = [System.IO.Path]::GetTempFileName()
  $json = ($paramObj | ConvertTo-Json -Depth 3)
  [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))

  $cmdId = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters file://$tmp --query "Command.CommandId" --output text
  if (-not $cmdId) { throw "Failed to send SSM command" }
  Write-Host ("SSM CommandId: {0}" -f $cmdId)

  Start-Sleep -Seconds 10
  $status = 'Pending'
  for ($i=0; $i -lt 30; $i++) {
    $status = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query "Status" --output text 2>$null
    if ($status -in @('Success','Failed','Cancelled','TimedOut')) { break }
    Start-Sleep -Seconds 5
  }
  Write-Host ("SSM Status: {0}" -f $status)
  $stdout = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query "StandardOutputContent" --output text
  $stderr = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query "StandardErrorContent" --output text

  $outDir = Join-Path $PSScriptRoot 'outputs'
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  $base = (Get-Date).ToString('yyyyMMdd_HHmmss') + "_" + $InstanceId
  $outFile = Join-Path $outDir ($base + '_stdout.txt')
  $errFile = Join-Path $outDir ($base + '_stderr.txt')
  [System.IO.File]::WriteAllText($outFile, $stdout, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($errFile, $stderr, [System.Text.UTF8Encoding]::new($false))
  Write-Host ("Saved: {0}" -f $outFile)
  if ($stderr) { Write-Host ("STDERR saved: {0}" -f $errFile) }
}

# --- Main ---
$ids = Get-MoodleInstanceIds -Region $Region
if (-not $ids -or $ids.Count -eq 0) {
  Write-Warning "No instances registered in the Moodle target group yet. Try again in a few minutes."
  exit 2
}

foreach ($id in $ids) {
  Invoke-LogSSM -InstanceId $id -Region $Region -TailLines $TailLines
}

Write-Host "Done."
