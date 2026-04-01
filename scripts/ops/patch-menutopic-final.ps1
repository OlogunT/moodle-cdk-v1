# Patch format_menutopic to guard against recursive deadlock in set_sectionnum()
# Uses base64-encoded Python to avoid heredoc escaping issues via SSM

param(
    [string]$Profile  = "tsin-account",
    [string]$Region   = "ca-central-1",
    [string]$Instance = "i-04aa12a6aa64b6e66"
)

Set-StrictMode -Off
$env:PYTHONUTF8 = '1'

# ---- 1. Build the Python patch script ----
$pyScript = @'
import sys, re

filepath = "/app/moodle/course/format/menutopic/lib.php"
with open(filepath, "r") as f:
    content = f.read()

# The exact string we want to replace (line 113-114 of the file)
OLD = '                $this->set_sectionnum($displaysection);\n                $USER->display[$courseid] = $displaysection;'
NEW = '''                // Guard against recursive deadlock: set_sectionnum() may call
                // get_fast_modinfo() which acquires the modinfo cache lock. If this
                // constructor is called during a cache rebuild (lock already held),
                // acquiring the lock again causes a fatal "Unable to acquire a lock for
                // caching" error. Catch moodle_exception so the page renders normally
                // (defaulting to section 0) rather than throwing a fatal error.
                try {
                    $this->set_sectionnum($displaysection);
                } catch (\\moodle_exception $e) {
                    debugging(
                        \'format_menutopic: set_sectionnum skipped during modinfo cache rebuild (lock contention avoided): \' . $e->getMessage(),
                        DEBUG_DEVELOPER
                    );
                }
                $USER->display[$courseid] = $displaysection;'''

if OLD in content:
    open(filepath, "w").write(content.replace(OLD, NEW, 1))
    print("PATCH_APPLIED_OK")
else:
    # Help diagnose: show context around set_sectionnum
    m = re.search(r'set_sectionnum\(\$displaysection\)', content)
    if m:
        print("CONTEXT: " + repr(content[max(0,m.start()-120):m.end()+200]))
    else:
        print("ERROR: set_sectionnum($displaysection) not found in file at all")
    sys.exit(1)
'@

# ---- 2. Base64-encode the Python script ----
$pyBytes = [System.Text.Encoding]::UTF8.GetBytes($pyScript)
$pyB64   = [System.Convert]::ToBase64String($pyBytes)

# ---- 3. Build the shell command (no heredoc, no quoting nightmares) ----
$shellCmd = (
    "set -e; " +
    "FILE=/app/moodle/course/format/menutopic/lib.php; " +
    "echo '=== backup ==='; cp `$FILE `${FILE}.bak-`$(date +%Y%m%d%H%M%S); " +
    "echo '=== apply patch ==='; " +
    "echo '$pyB64' | base64 -d > /tmp/mt_patch.py && python3 /tmp/mt_patch.py; " +
    "echo '=== php syntax check ==='; php -l `$FILE && echo PHP_SYNTAX_OK; " +
    "echo '=== verify patch lines ==='; grep -n 'moodle_exception\|Guard against\|set_sectionnum' `$FILE | head -20; " +
    "echo '=== DONE ==='"
)

# ---- 4. Write the SSM params JSON (avoid ConvertTo-Json escaping issues) ----
$pf = "C:\Windows\Temp\patch-mt-final.json"
$json = '{"commands":["' + $shellCmd.Replace('\','\\').Replace('"','\"') + '"]}'
[System.IO.File]::WriteAllText($pf, $json, [System.Text.Encoding]::UTF8)
Write-Host "Params file written: $pf ($((Get-Item $pf).Length) bytes)"

# ---- 5. Send SSM command ----
$id = (aws --profile $Profile --region $Region --cli-connect-timeout 4 --cli-read-timeout 8 --no-cli-pager `
    ssm send-command `
    --instance-ids $Instance `
    --document-name AWS-RunShellScript `
    --parameters "file://$pf" `
    --timeout-seconds 90 `
    --query "Command.CommandId" --output text 2>&1).Trim()

if ($id -notmatch '^[0-9a-f-]{36}$') {
    Write-Host "ERROR sending command: $id"; exit 1
}
Write-Host "CMD_ID: $id"

# ---- 6. Poll for result (up to 80 seconds) ----
Write-Host "Waiting for SSM result..."
Start-Sleep 30
for ($attempt = 1; $attempt -le 5; $attempt++) {
    $r = aws --profile $Profile --region $Region --cli-connect-timeout 4 --cli-read-timeout 8 --no-cli-pager `
        ssm get-command-invocation --command-id $id --instance-id $Instance 2>&1
    $txt = ($r | Out-String) -replace '[^\x09\x0A\x0D\x20-\x7E]','?'
    if ($txt -match '"Status"\s*:\s*"(Success|Failed|TimedOut)"') {
        Write-Host $txt
        break
    }
    Write-Host "Attempt $attempt - still InProgress, waiting 10s..."
    Start-Sleep 10
}

