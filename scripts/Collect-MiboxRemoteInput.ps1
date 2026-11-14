$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$destination = Join-Path $repo ('artifacts/remote-input/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $destination | Out-Null
$queries = [ordered]@{
    bootIdBefore = 'cat /proc/sys/kernel/random/boot_id'
    fingerprint = 'getprop ro.build.fingerprint'
    bootCompleted = 'getprop sys.boot_completed'
    inputDevices = 'cat /proc/bus/input/devices'
    inputNodes = 'ls -l /dev/input'
    inputCapabilities = 'getevent -lp'
    remoteConfig = 'ls -l /system/etc/remote.conf'
    irSysfs = 'ls -l /sys/devices/platform/ir-meson6-mi'
    remoteClass = 'ls -l /sys/class/remote'
    kernelIrLog = 'dmesg'
    bootIdAfter = 'cat /proc/sys/kernel/random/boot_id'
}
$results = [ordered]@{}
foreach ($entry in $queries.GetEnumerator()) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $adb
    $start.Arguments = '-s 248243005297 shell ' + $entry.Value
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(8000)
    if ($timedOut) { $process.Kill() }
    $process.WaitForExit()
    $result = [ordered]@{ Command = $entry.Value; ExitCode = $process.ExitCode
        TimedOut = $timedOut; Output = $stdout.Result; Error = $stderr.Result }
    $process.Dispose()
    if ($entry.Key -eq 'kernelIrLog') {
        $result.Output = (($result.Output -split "`n" | Where-Object { $_ -match 'ir_meson|ir-meson|keyup|keydown|ir_fiq|keycode|denied|permitted' }) -join "`n")
        $result['HostFilter'] = 'Retained only IR/key diagnostics and permission errors; no kernel logging configuration changed.'
    }
    $results[$entry.Key] = $result
    $result | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destination ($entry.Key + '.json'))
}
[ordered]@{ ObservedAt = (Get-Date).ToString('o'); Queries = $results
    Scope = 'Read-only Android identity and input capability queries; no input events injected'
    RebootRequested = $false; DeviceFilesWritten = $false } |
    ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destination 'result.json')
Write-Output $destination
Write-Output 'Read-only inventory retained; inspect individual outputs and timeouts before interpreting results.'
