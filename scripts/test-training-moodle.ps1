#!/usr/bin/env pwsh
#
# Test Training Moodle Site
# Tests the training.tsin.ca Moodle instance
#

param(
  [string]$Region = "ca-central-1",
  [string]$Stack  = "TrainingMoodleCdkStack"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Testing Training Moodle Site                                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Get stack outputs
function Get-StackOutput($Region,$Stack,$Key){
  $o = aws cloudformation describe-stacks --region $Region --stack-name $Stack --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue" --output text 2>$null
  return $o
}

Write-Host "Step 1: Getting Stack Information" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

$url = Get-StackOutput -Region $Region -Stack $Stack -Key 'TrainingMoodleUrl'
$albDns = Get-StackOutput -Region $Region -Stack $Stack -Key 'TrainingMoodleAlbDns'

if (-not $url) { 
    Write-Host "✗ Could not find MoodleUrl output from stack" -ForegroundColor Red
    exit 1
}

Write-Host "  Moodle URL: $url" -ForegroundColor White
Write-Host "  ALB DNS: $albDns" -ForegroundColor White
Write-Host ""

# Test 1: Health Check
Write-Host "Step 2: Testing Health Endpoint" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

try {
  $healthCode = & curl.exe -s -o NUL -w "%{http_code}" "$url/health"
  if ($healthCode -eq '200') {
    Write-Host "  ✓ Health check: HTTP $healthCode" -ForegroundColor Green
  } else {
    Write-Host "  ✗ Health check: HTTP $healthCode (expected 200)" -ForegroundColor Red
  }
} catch { 
  Write-Host "  ✗ Health check failed: $_" -ForegroundColor Red
  $healthCode = "000"
}
Write-Host ""

# Test 2: Homepage
Write-Host "Step 3: Testing Homepage" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

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
  
  if ($code -eq '200') {
    Write-Host "  ✓ Homepage: HTTP $code" -ForegroundColor Green
    Write-Host "    Redirects: $redir" -ForegroundColor Gray
    Write-Host "    Final URL: $eff" -ForegroundColor Gray
  } else {
    Write-Host "  ✗ Homepage: HTTP $code (expected 200)" -ForegroundColor Red
  }
} catch { 
  Write-Host "  ✗ Homepage test failed: $_" -ForegroundColor Red
  $code = "curl_error" 
}
Write-Host ""

# Test 3: Login Page
Write-Host "Step 4: Testing Login Page" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

try {
  $loginCode = & curl.exe -s -o NUL -w "%{http_code}" "$url/login/index.php"
  if ($loginCode -eq '200') {
    Write-Host "  ✓ Login page: HTTP $loginCode" -ForegroundColor Green
  } else {
    Write-Host "  ✗ Login page: HTTP $loginCode (expected 200)" -ForegroundColor Red
  }
} catch { 
  Write-Host "  ✗ Login page test failed: $_" -ForegroundColor Red
  $loginCode = "000"
}
Write-Host ""

# Test 4: Check for redirect loops
Write-Host "Step 5: Checking for Redirect Loops" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

if ($redir -ge 10) {
  Write-Host "  ✗ Possible redirect loop detected ($redir redirects)" -ForegroundColor Red
} elseif ($redir -gt 0) {
  Write-Host "  ⚠ $redir redirects (acceptable)" -ForegroundColor Yellow
} else {
  Write-Host "  ✓ No redirects" -ForegroundColor Green
}
Write-Host ""

# Summary
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Test Summary                                                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$allPassed = $true

if ($healthCode -eq '200') {
  Write-Host "  ✓ Health Check: PASS" -ForegroundColor Green
} else {
  Write-Host "  ✗ Health Check: FAIL" -ForegroundColor Red
  $allPassed = $false
}

if ($code -eq '200') {
  Write-Host "  ✓ Homepage: PASS" -ForegroundColor Green
} else {
  Write-Host "  ✗ Homepage: FAIL" -ForegroundColor Red
  $allPassed = $false
}

if ($loginCode -eq '200') {
  Write-Host "  ✓ Login Page: PASS" -ForegroundColor Green
} else {
  Write-Host "  ✗ Login Page: FAIL" -ForegroundColor Red
  $allPassed = $false
}

if ($redir -lt 10) {
  Write-Host "  ✓ No Redirect Loop: PASS" -ForegroundColor Green
} else {
  Write-Host "  ✗ Redirect Loop Detected: FAIL" -ForegroundColor Red
  $allPassed = $false
}

Write-Host ""

if ($allPassed) {
  Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
  Write-Host "║   ✓ ALL TESTS PASSED - Site is ready!                        ║" -ForegroundColor Green
  Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
  Write-Host ""
  Write-Host "You can now access the site at: $url" -ForegroundColor Cyan
  exit 0
} else {
  Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
  Write-Host "║   ✗ SOME TESTS FAILED - Investigation needed                 ║" -ForegroundColor Red
  Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
  Write-Host ""
  Write-Host "Run the following to check instance status:" -ForegroundColor Yellow
  Write-Host "  pwsh scripts/verify-training-instance.ps1" -ForegroundColor Gray
  exit 1
}

