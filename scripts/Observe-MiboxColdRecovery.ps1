param([ValidateRange(10,600)][int]$TimeoutSeconds = 180, [switch]$BaselineOnly)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$destination = Join-Path $repo ('artifacts/recovery-entry/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $destination | Out-Null
function Read-Adb([string]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $adb; $start.Arguments = $Arguments
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(4000)
    if ($timedOut) { $process.Kill() }
    $process.WaitForExit()
    $result = [ordered]@{ ExitCode = $process.ExitCode; TimedOut = $timedOut
        Output = $stdout.Result.Trim(); Error = $stderr.Result.Trim() }
    $process.Dispose()
    return $result
}
function Snapshot {
    $usb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^USB\\VID_(1B8E|18D1|2717)&' } |
        Select-Object Status,Class,FriendlyName,InstanceId)
    return [ordered]@{ At = (Get-Date).ToString('o'); Adb = (Read-Adb 'devices -l'); Usb = $usb }
}
$baseline = [ordered]@{
    BootId = (Read-Adb '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id')
    Fingerprint = (Read-Adb '-s 248243005297 shell getprop ro.build.fingerprint')
    BootCompleted = (Read-Adb '-s 248243005297 shell getprop sys.boot_completed')
    Snapshot = (Snapshot)
}
$baseline | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destination 'baseline.json')
if ($baseline.BootId.TimedOut -or $baseline.BootId.ExitCode -ne 0 -or
    $baseline.BootId.Output -notmatch '^[0-9a-f-]{36}$' -or
    $baseline.BootCompleted.Output -ne '1' -or
    $baseline.Fingerprint.Output -ne 'Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys') {
    throw "Stock Android baseline not confirmed; no device change requested. Evidence: $destination"
}
if ($BaselineOnly) { Write-Output "BASELINE_ONLY_PASS: $destination"; exit 0 }
Write-Output "COLD_RECOVERY_OBSERVER_STARTED: $destination"
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    Snapshot | ConvertTo-Json -Depth 7 -Compress | Add-Content -Encoding UTF8 -LiteralPath (Join-Path $destination 'events.jsonl')
    Start-Sleep -Seconds 3
}
$final = [ordered]@{
    Snapshot = (Snapshot)
    BootId = (Read-Adb '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id')
    BootCompleted = (Read-Adb '-s 248243005297 shell getprop sys.boot_completed')
    Fingerprint = (Read-Adb '-s 248243005297 shell getprop ro.build.fingerprint')
    Scope = 'Observation only; no host reboot, loader, key injection or storage command'
    RecoveryMenuConfirmed = $false; RestorationTested = $false
}
$final | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destination 'final.json')
Write-Output "COLD_RECOVERY_OBSERVER_FINISHED: $destination"
