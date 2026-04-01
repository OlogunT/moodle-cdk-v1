$b64 = (Get-Content 'C:\Temp\fix_debug_b64.txt' -Raw).Trim()
$bytes = [Convert]::FromBase64String($b64)
$decoded = [Text.Encoding]::UTF8.GetString($bytes)
$decoded | Out-File 'C:\Temp\fix_debug_decoded.py' -Encoding utf8
Write-Host "Total lines: $(($decoded -split "`n").Count)"
($decoded -split "`n") | Select-String 'format_menutopic'

