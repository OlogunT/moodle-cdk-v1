# Test site reachability and login with tsin-admin credentials
$phpCode = @'
<?php
define('CLI_SCRIPT', true);
require('/app/moodle/config.php');

echo "=== 1. Test localhost reachability ===\n";
$ch = curl_init('http://localhost/login/index.php');
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 60);
curl_setopt($ch, CURLOPT_HEADER, true);
curl_setopt($ch, CURLOPT_NOBODY, false);
$resp = curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$time = curl_getinfo($ch, CURLINFO_TOTAL_TIME);
curl_close($ch);
echo "Login page: HTTP $code in {$time}s\n";

if (strpos($resp, 'logintoken') !== false) {
    echo "Login form found - extracting token\n";
    preg_match('/logintoken.*?value="([^"]+)"/', $resp, $m);
    $token = $m[1] ?? '';
    echo "Token: " . substr($token, 0, 10) . "...\n";

    // Extract session cookie
    preg_match('/MoodleSession=([^;]+)/', $resp, $cm);
    $cookie = $cm[1] ?? '';
    echo "Session: " . substr($cookie, 0, 10) . "...\n";

    if ($token && $cookie) {
        echo "\n=== 2. Attempt login ===\n";
        $ch2 = curl_init('http://localhost/login/index.php');
        curl_setopt($ch2, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch2, CURLOPT_TIMEOUT, 60);
        curl_setopt($ch2, CURLOPT_HEADER, true);
        curl_setopt($ch2, CURLOPT_POST, true);
        curl_setopt($ch2, CURLOPT_POSTFIELDS, http_build_query([
            'username' => 'tsin-admin',
            'password' => 'Tsin@2025!@#',
            'logintoken' => $token,
        ]));
        curl_setopt($ch2, CURLOPT_COOKIE, "MoodleSession=$cookie");
        curl_setopt($ch2, CURLOPT_FOLLOWLOCATION, false);
        $resp2 = curl_exec($ch2);
        $code2 = curl_getinfo($ch2, CURLINFO_HTTP_CODE);
        $time2 = curl_getinfo($ch2, CURLINFO_TOTAL_TIME);
        curl_close($ch2);
        echo "Login POST: HTTP $code2 in {$time2}s\n";

        if ($code2 == 303) {
            preg_match('/Location: (.+)/', $resp2, $lm);
            $loc = trim($lm[1] ?? '');
            echo "Redirect to: $loc\n";

            // Extract new session cookie
            preg_match('/MoodleSession=([^;]+)/', $resp2, $cm2);
            $newcookie = $cm2[1] ?? $cookie;

            echo "\n=== 3. Follow redirect ===\n";
            $ch3 = curl_init("http://localhost" . parse_url($loc, PHP_URL_PATH));
            curl_setopt($ch3, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch3, CURLOPT_TIMEOUT, 60);
            curl_setopt($ch3, CURLOPT_COOKIE, "MoodleSession=$newcookie");
            $resp3 = curl_exec($ch3);
            $code3 = curl_getinfo($ch3, CURLINFO_HTTP_CODE);
            $time3 = curl_getinfo($ch3, CURLINFO_TOTAL_TIME);
            curl_close($ch3);
            echo "Dashboard: HTTP $code3 in {$time3}s\n";
            if (strpos($resp3, 'tsin-admin') !== false || strpos($resp3, 'Dashboard') !== false) {
                echo "LOGIN SUCCESSFUL - user logged in\n";
            } else if (strpos($resp3, 'error') !== false || strpos($resp3, 'Error') !== false) {
                preg_match('/<title>([^<]+)</', $resp3, $tm);
                echo "Page title: " . ($tm[1] ?? 'unknown') . "\n";
                // Check for error messages
                if (preg_match('/class="alert[^"]*"[^>]*>([^<]+)/', $resp3, $em)) {
                    echo "Error: " . $em[1] . "\n";
                }
            } else {
                preg_match('/<title>([^<]+)</', $resp3, $tm);
                echo "Page title: " . ($tm[1] ?? 'unknown') . "\n";
            }

            echo "\n=== 4. Test course edit page ===\n";
            $ch4 = curl_init("http://localhost/course/edit.php?id=114");
            curl_setopt($ch4, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch4, CURLOPT_TIMEOUT, 60);
            curl_setopt($ch4, CURLOPT_COOKIE, "MoodleSession=$newcookie");
            curl_setopt($ch4, CURLOPT_FOLLOWLOCATION, true);
            $resp4 = curl_exec($ch4);
            $code4 = curl_getinfo($ch4, CURLINFO_HTTP_CODE);
            $time4 = curl_getinfo($ch4, CURLINFO_TOTAL_TIME);
            curl_close($ch4);
            echo "Course edit: HTTP $code4 in {$time4}s\n";
            preg_match('/<title>([^<]+)</', $resp4, $tm4);
            echo "Page title: " . ($tm4[1] ?? 'unknown') . "\n";
            if (strpos($resp4, 'error') !== false || strpos($resp4, 'exception') !== false) {
                if (preg_match('/class="alert[^"]*"[^>]*>([^<]+)/', $resp4, $em4)) {
                    echo "Error: " . $em4[1] . "\n";
                }
                if (preg_match('/class="errormessage[^"]*"[^>]*>([^<]+)/', $resp4, $em5)) {
                    echo "Error msg: " . $em5[1] . "\n";
                }
            }
        } else {
            echo "Login may have failed - not a redirect\n";
            preg_match('/<title>([^<]+)</', $resp2, $tm);
            echo "Page title: " . ($tm[1] ?? 'unknown') . "\n";
        }
    }
} else {
    echo "Login form NOT found in response\n";
    echo "Response snippet: " . substr($resp, 0, 500) . "\n";
}

echo "\nAll tests complete\n";
'@

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($phpCode))
$shellCmd = "echo $b64 | base64 -d > /tmp/test_login.php && php /tmp/test_login.php 2>&1 && echo EXIT=0"

$params = @{ commands = @($shellCmd) }
$jsonParams = $params | ConvertTo-Json -Compress

$cmdId = aws --profile tsin-account --region ca-central-1 ssm send-command `
    --document-name "AWS-RunShellScript" `
    --targets "Key=instanceIds,Values=i-011c65cd247389ee6" `
    --parameters $jsonParams `
    --timeout-seconds 300 `
    --query 'Command.CommandId' --output text

Write-Host "CMD: $cmdId"
Start-Sleep 90
aws --profile tsin-account --region ca-central-1 --cli-read-timeout 15 ssm get-command-invocation `
    --command-id $cmdId `
    --instance-id i-011c65cd247389ee6 `
    --query '{S:Status,O:StandardOutputContent,E:StandardErrorContent}' --output json 2>&1

