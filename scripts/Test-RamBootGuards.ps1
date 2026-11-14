# Isolated child-script fixtures: never launches ADB or opens USB.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path $repo ('target/ram-boot-guard-tests/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$scripts = Join-Path $root 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ram-boot.ps1') -Destination (Join-Path $scripts 'ram-boot.ps1')
$checker = @'
param($Action,$Candidate,[switch]$VerifyOnly)
$fixture=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../fixture.json') | ConvertFrom-Json
if($fixture.Fail){throw 'Injected checker failure'}
$fixture.Record | ConvertTo-Json
'@
$checker | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $scripts 'Test-MiboxLoaderRam.ps1')
$results = @()
foreach ($name in @('valid','wrong-hash','wrong-size','usb-access-claimed','checker-failed')) {
    $record = [ordered]@{ UsbAccessed=$false; Bytes=8388608; Sha256='5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa' }
    if($name -eq 'wrong-hash'){$record.Sha256='0'*64}
    if($name -eq 'wrong-size'){$record.Bytes=8388607}
    if($name -eq 'usb-access-claimed'){$record.UsbAccessed=$true}
    [ordered]@{Fail=($name -eq 'checker-failed');Record=$record} | ConvertTo-Json -Depth 4 |
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $root 'fixture.json')
    $action = if($name -eq 'valid'){'Check'}else{'RoundTrip'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $PSHOME 'powershell.exe'
    $start.Arguments="-NoProfile -File `"$(Join-Path $scripts 'ram-boot.ps1')`" -Action $action"
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $p=[Diagnostics.Process]::new();$p.StartInfo=$start
    [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit(20000)){$p.Kill();$p.WaitForExit();throw 'Guard test timed out'}
    $p.WaitForExit();$code=$p.ExitCode;$p.Dispose()
    $latest=Get-ChildItem -LiteralPath (Join-Path $root 'artifacts/ram-boot') -Directory |
        Sort-Object Name | Select-Object -Last 1
    $proof=Get-Content -Raw -LiteralPath (Join-Path $latest.FullName 'result.json') | ConvertFrom-Json
    $passed=($proof.DeviceAccessed -eq $false -and $proof.LoaderRequestSent -eq $false -and
        (($name -eq 'valid' -and $code -eq 0 -and $proof.Stage -eq 'LocalCheckPassed') -or
         ($name -ne 'valid' -and $code -ne 0 -and $null -ne $proof.Failure)))
    $results += [pscustomobject]@{Case=$name;Pass=$passed;ExitCode=$code;DeviceAccessed=$proof.DeviceAccessed;LoaderRequestSent=$proof.LoaderRequestSent}
    if(-not $passed){throw "Guard case failed: $name; $($out.Result) $($err.Result)"}
}
$destination=Join-Path $repo 'artifacts/ram-boot/guard-tests.json'
New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
$results | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $destination
Write-Output "RAM_BOOT_GUARDS_PASS: $($results.Count) cases; no device access"
