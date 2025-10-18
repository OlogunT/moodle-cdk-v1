param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "MoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-StackOutput($Region,$Stack,$Key){
  $o = aws cloudformation describe-stacks --region $Region --stack-name $Stack --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue" --output text 2>$null
  return $o
}

$url = Get-StackOutput -Region $Region -Stack $Stack -Key 'MoodleUrl'
if (-not $url) { throw "Could not find MoodleUrl output" }

Write-Host ("MoodleUrl: {0}" -f $url)

# Health check
try {
  $healthCode = & curl.exe -s -o NUL -w "%{http_code}" "$url/health"
} catch { $healthCode = "000" }
Write-Host ("/health HTTP {0}" -f $healthCode)

# Homepage request with redirect following limited
$code = ""; $eff = ""; $redir = ""
try {
  $fmt = "%{http_code} %{url_effective} %{num_redirects}\n"
  $res = & curl.exe -sL --max-redirs 10 -o $null -w $fmt "$url/"
  $parts = $res.Trim().Split(' ')
  if ($parts.Length -ge 3) {
    $code = $parts[0]
    $eff = $parts[1]
    $redir = $parts[2]
  } else { $code = $res.Trim() }
} catch { $code = "curl_error" }
Write-Host ("/ HTTP {0} redirects={1} final={2}" -f $code,$redir,$eff)

if ($healthCode -eq '200' -and $code -eq '200') {
  Write-Host "OK: HTTP works without redirect loop"
  exit 0
}

if ($code -eq 'curl_error' -or $redir -ge 10) {
  Write-Host "FAIL: Possible redirect loop or curl error"
  exit 2
}

Write-Host "WARN: Unexpected status. Investigate."
exit 1

