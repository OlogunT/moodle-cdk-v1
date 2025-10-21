Write-Host "=== Configuring Training Moodle SMTP using SES ===" -ForegroundColor Cyan
Write-Host ""

# Read the script content
$scriptContent = Get-Content -Path "scripts/configure-training-moodle-ses.sh" -Raw

# Upload and execute the script
Write-Host "Uploading and executing configuration script..." -ForegroundColor Yellow
$cmd = aws ssm send-command `
    --instance-ids i-06e7f96652b2b9620 `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=[`"$scriptContent`"]" `
    --region ca-central-1 `
    --output json | ConvertFrom-Json

Write-Host "Command ID: " -NoNewline -ForegroundColor Green
Write-Host $cmd.Command.CommandId -ForegroundColor Yellow
Start-Sleep -Seconds 20

$output = aws ssm get-command-invocation --command-id $cmd.Command.CommandId --instance-id i-06e7f96652b2b9620 --region ca-central-1 --query "StandardOutputContent" --output text
Write-Host $output

Write-Host ""
$errors = aws ssm get-command-invocation --command-id $cmd.Command.CommandId --instance-id i-06e7f96652b2b9620 --region ca-central-1 --query "StandardErrorContent" --output text
if ($errors -and $errors.Trim()) { 
    Write-Host "Errors: " -ForegroundColor Red
    Write-Host $errors -ForegroundColor Red
} else { 
    Write-Host "✓ No errors - Configuration completed successfully!" -ForegroundColor Green
}

