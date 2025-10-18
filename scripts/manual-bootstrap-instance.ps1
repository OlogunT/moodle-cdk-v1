param(
  [Parameter(Mandatory=$true)][string]$InstanceId,
  [string]$Region = "ca-central-1",
  [string]$Stack = "MoodleCdkStack",
  [string]$MoodleUrl = "https://elearning.tsin.ca",
  [int]$TimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "Region: $Region  Stack: $Stack  Instance: $InstanceId"

# 1) Discover required resource IDs from the stack
$res = aws cloudformation list-stack-resources --stack-name $Stack --region $Region --output json | ConvertFrom-Json
if (-not $res) { throw "Unable to list stack resources for $Stack" }
$resources = $res.StackResourceSummaries

$efsRes = $resources | Where-Object { $_.ResourceType -eq 'AWS::EFS::FileSystem' }
if ($efsRes.Count -lt 2) { Write-Warning "Found fewer than 2 EFS file systems in stack. Will proceed with best-effort mapping." }
$efsApp = $efsRes | Where-Object { $_.LogicalResourceId -match 'App|AppFile|AppEfs' } | Select-Object -First 1
$efsData = $efsRes | Where-Object { $_.LogicalResourceId -match 'Data|DataFile|DataEfs' } | Select-Object -First 1
if (-not $efsApp) { $efsApp = $efsRes | Select-Object -First 1 }
if (-not $efsData) { $efsData = $efsRes | Where-Object { $_.PhysicalResourceId -ne $efsApp.PhysicalResourceId } | Select-Object -First 1 }
$appEfsId = $efsApp.PhysicalResourceId
$dataEfsId = $efsData.PhysicalResourceId

# DB secret
$secretRes = $resources | Where-Object { $_.ResourceType -eq 'AWS::SecretsManager::Secret' } | Select-Object -First 1
if (-not $secretRes) { throw "No SecretsManager::Secret found in stack." }
$secretDetail = aws secretsmanager describe-secret --secret-id $secretRes.PhysicalResourceId --region $Region --output json | ConvertFrom-Json
$dbSecretArn = $secretDetail.ARN

# EFS Security Group (best-effort by logical name match)
$sgRes = $resources | Where-Object { $_.ResourceType -eq 'AWS::EC2::SecurityGroup' }
$efsSg = $sgRes | Where-Object { $_.LogicalResourceId -match 'Efs|EFS' } | Select-Object -First 1
$efsSgId = $efsSg.PhysicalResourceId

# Account ID for scripts bucket
$account = aws sts get-caller-identity --query Account --output text --region $Region
$scriptBucket = "moodle-scripts-$account-$Region"

Write-Host "APP_EFS_ID=$appEfsId"
Write-Host "DATA_EFS_ID=$dataEfsId"
Write-Host "DB_SECRET_ARN=$dbSecretArn"
Write-Host "EFS_SG_ID=$efsSgId"
Write-Host "SCRIPT_BUCKET=$scriptBucket"
Write-Host "MOODLE_WWWROOT=$MoodleUrl"

# 2) Build the SSM command
$bash = @(
  "set -euo pipefail",
  "export APP_EFS_ID=\"$appEfsId\"",
  "export DATA_EFS_ID=\"$dataEfsId\"",
  "export REGION=\"$Region\"",
  "export DB_SECRET_ARN=\"$dbSecretArn\"",
  "export EFS_SG_ID=\"$efsSgId\"",
  "export MOODLE_WWWROOT=\"$MoodleUrl\"",
  "export SCRIPT_BUCKET=\"$scriptBucket\"",
  "command -v aws >/dev/null 2>&1 || yum install -y awscli jq",
  "aws s3 cp \"s3://$scriptBucket/bootstrap-moodle.sh\" /tmp/bootstrap-moodle.sh",
  "chmod +x /tmp/bootstrap-moodle.sh",
  "/tmp/bootstrap-moodle.sh"
) -join '; '

$cmdArray = @("bash -lc '" + ($bash -replace "'", "'\\''") + "'")
$params = @{ commands = $cmdArray; executionTimeout = @($TimeoutSeconds.ToString()) } | ConvertTo-Json -Compress
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $params -Encoding ascii

Write-Host "Sending SSM command..."
$cmdId = aws ssm send-command --instance-ids $InstanceId --document-name AWS-RunShellScript --parameters file://$tmp --comment "Manual bootstrap Moodle" --region $Region --query 'Command.CommandId' --output text
if (-not $cmdId) { throw "Failed to send SSM command" }
Write-Host ("SSM CommandId: {0}" -f $cmdId)

# 3) Poll status
for ($i=0; $i -lt 120; $i++) {
  $inv = aws ssm list-command-invocations --command-id $cmdId --details --region $Region --output json | ConvertFrom-Json
  $status = $inv.CommandInvocations[0].Status
  Write-Host ("[{0}] Status: {1}" -f $i, $status)
  if ($status -in @('Success','Cancelled','TimedOut','Failed','Cancelling')) { break }
  Start-Sleep -Seconds 10
}

# 4) Fetch output
$out = aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId --region $Region --output json | ConvertFrom-Json
Write-Host "--- STDOUT (truncated) ---"
$out.StandardOutputContent.Substring(0, [Math]::Min(4000, $out.StandardOutputContent.Length))
Write-Host "--- STDERR (truncated) ---" -ForegroundColor Yellow
$out.StandardErrorContent.Substring(0, [Math]::Min(2000, $out.StandardErrorContent.Length))

if ($out.Status -ne 'Success') { Write-Warning ("Command final status: {0}" -f $out.Status); exit 2 }
Write-Host "Manual bootstrap completed successfully." -ForegroundColor Green

