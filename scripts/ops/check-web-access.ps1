# Check what happens when we access the site via curl - follow redirects
$shellCmd = @"
echo "=== Testing site access ==="
curl -s -L -o /dev/null -w "URL: %{url_effective}\nHTTP: %{http_code}\nTime: %{time_total}s\nRedirects: %{num_redirects}\n" http://localhost/ 2>&1
echo ""
echo "=== Testing with redirect trace ==="
curl -s -L -v -o /dev/null http://localhost/ 2>&1 | grep -E '(Location:|HTTP/|< )'
echo ""
echo "=== Check bootstrap cache ==="
ls -la /data/moodledata/localcache/bootstrap.php 2>/dev/null || echo "No bootstrap.php found"
echo ""
echo "=== Check if climaintenance exists ==="
ls -la /data/moodledata/climaintenance.html 2>/dev/null || echo "No climaintenance.html"
echo ""
echo "=== Check config_plugins for upgraderunning ==="
php -r 'define("CLI_SCRIPT",true);define("ABORT_AFTER_CONFIG",true);require("/app/moodle/config.php");\$d=new PDO("mysql:host={\$CFG->dbhost};dbname={\$CFG->dbname}",\$CFG->dbuser,\$CFG->dbpass);\$r=\$d->query("SELECT * FROM mdl_config WHERE name LIKE \"%upgrad%\" OR name LIKE \"%admin%pending%\"")->fetchAll(PDO::FETCH_ASSOC);foreach(\$r as \$row)echo \$row["name"]."=".\$row["value"]."\n";' 2>&1
"@

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 120 `
    --query 'Command.CommandId' --output text

Write-Host "Command ID: $cmdId"
Start-Sleep 30

$result = aws --profile tsin-account --region ca-central-1 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

Write-Host $result

