param([string]$Serial = '248243005297')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$adbPath = Join-Path $repoRoot 'phone-tools/platform-tools/adb.exe'
$binaryPath = Join-Path $repoRoot 'target/armv7-unknown-linux-musleabihf/release/mibox-usb-acm-test'
$evidenceDirectory = Join-Path $repoRoot ('artifacts/usb-acm/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

function Invoke-AdbBounded([string]$Arguments, [int]$TimeoutMs = 10000) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $adbPath
    $startInfo.Arguments = "-s $Serial $Arguments"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $adbProcess = [Diagnostics.Process]::new()
    $adbProcess.StartInfo = $startInfo
    [void]$adbProcess.Start()
    $outTask = $adbProcess.StandardOutput.ReadToEndAsync()
    $errTask = $adbProcess.StandardError.ReadToEndAsync()
    if (-not $adbProcess.WaitForExit($TimeoutMs)) {
        $adbProcess.Kill()
        $adbProcess.WaitForExit()
        throw "ADB command timed out: $Arguments"
    }
    $adbProcess.WaitForExit()
    $result = [pscustomobject]@{ ExitCode=$adbProcess.ExitCode; Output=$outTask.Result; Error=$errTask.Result }
    $adbProcess.Dispose()
    return $result
}

$state = Invoke-AdbBounded 'get-state'
if ($state.ExitCode -ne 0 -or $state.Output.Trim() -ne 'device') { throw 'USB ADB is unavailable; no test launched' }
$beforeBoot = Invoke-AdbBounded 'shell cat /proc/sys/kernel/random/boot_id'
$beforeBootId = $beforeBoot.Output.Trim()
if ($beforeBootId -notmatch '^[0-9a-f-]{36}$') { throw 'Cannot record boot ID; no test launched' }
$beforeBootId | Set-Content (Join-Path $evidenceDirectory 'boot-id-before.txt') -Encoding UTF8
$upload = Invoke-AdbBounded "push `"$binaryPath`" /data/local/tmp/mibox-usb-acm-test"
if ($upload.ExitCode -ne 0) { throw "Upload failed: $($upload.Error)" }
$mode = Invoke-AdbBounded 'shell chmod 755 /data/local/tmp/mibox-usb-acm-test'
if ($mode.ExitCode -ne 0) { throw 'chmod failed; no test launched' }
$launch = Invoke-AdbBounded 'shell /data/local/tmp/mibox-usb-acm-test'
$launch.Output | Set-Content (Join-Path $evidenceDirectory 'launch.txt') -Encoding UTF8
if ($launch.Output -notmatch 'ACM_TEST_LAUNCH_ACKNOWLEDGED') { throw "Launch not acknowledged: $($launch.Error) $($launch.Output)" }

$clock = [Diagnostics.Stopwatch]::StartNew()
$serialPort = $null
$portName = $null
$received = ''
$sawReady = $false
$sawAck = $false
$events = @()
$seen = @{}
try {
    while ($clock.Elapsed.TotalSeconds -lt 35) {
        if (-not $serialPort) {
            $candidates = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
                $_.InstanceId -match '^USB\\VID_18D1&PID_4E41'
            })
            foreach ($device in $candidates) {
                $identity = "$($device.InstanceId):$($device.Status):$($device.FriendlyName)"
                if (-not $seen.ContainsKey($identity)) {
                    $seen[$identity] = $true
                    $events += "$([int]$clock.Elapsed.TotalSeconds)s $identity"
                }
                if ($device.Status -eq 'OK' -and $device.FriendlyName -match '\((COM\d+)\)') {
                    $portName = $Matches[1]
                    try {
                        $candidatePort = [IO.Ports.SerialPort]::new($portName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
                        $candidatePort.DtrEnable = $true
                        $candidatePort.RtsEnable = $true
                        $candidatePort.ReadTimeout = 200
                        $candidatePort.WriteTimeout = 500
                        $candidatePort.Open()
                        $serialPort = $candidatePort
                        $events += "Opened $portName"
                    } catch {
                        if ($candidatePort) { $candidatePort.Dispose() }
                        $events += "Open $portName failed: $($_.Exception.Message)"
                    }
                }
            }
        }
        if ($serialPort) {
            try {
                $serialPort.Write("MIBOX_HOST_PING`n")
                Start-Sleep -Milliseconds 100
                $received += $serialPort.ReadExisting()
                $sawReady = $received.Contains('MIBOX_ACM_READY')
                $sawAck = $received.Contains('MIBOX_DEVICE_ACK')
                if ($sawReady -and $sawAck) { break }
            } catch {
                $events += "Serial I/O: $($_.Exception.Message)"
                $serialPort.Dispose()
                $serialPort = $null
            }
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    if ($serialPort) { $serialPort.Dispose() }
}
# Wait for the normal 30-second device-side restore before checking ADB.
# If that worker failed, the independent restore process runs at 45 seconds.
while ($clock.Elapsed.TotalSeconds -lt 32) { Start-Sleep -Milliseconds 500 }
$adbRestored = $false
while ($clock.Elapsed.TotalSeconds -lt 53) {
    try {
        $check = Invoke-AdbBounded 'shell echo ACM_RESTORE_CHECK' 1500
        if ($check.Output -match 'ACM_RESTORE_CHECK') { $adbRestored = $true; break }
    } catch { $events += $_.Exception.Message }
    Start-Sleep -Milliseconds 500
}
$received | Set-Content (Join-Path $evidenceDirectory 'serial.txt') -Encoding UTF8
$afterBootId = $null
$restorationMarker = $false
if ($adbRestored) {
    try {
        $afterBoot = Invoke-AdbBounded 'shell cat /proc/sys/kernel/random/boot_id'
        $afterBootId = $afterBoot.Output.Trim()
        $afterBootId | Set-Content (Join-Path $evidenceDirectory 'boot-id-after.txt') -Encoding UTF8
        $restoreCheck = Invoke-AdbBounded 'shell cat /data/local/tmp/mibox-acm-test-v3/restored'
        $restorationMarker = $restoreCheck.Output.Trim() -eq 'USB_STATE_RESTORED'
    } catch { $events += "Restoration verification failed: $($_.Exception.Message)" }
}
$events | Set-Content (Join-Path $evidenceDirectory 'events.txt') -Encoding UTF8
$sameBoot = $beforeBootId -eq $afterBootId
$result = [pscustomobject]@{
    Port=$portName; DeviceToHostReady=$sawReady; HostRoundTripAck=$sawAck
    AdbShellRestored=$adbRestored; ElapsedSeconds=$clock.Elapsed.TotalSeconds
    SameBootSession=$sameBoot; RestorationMarkerVerified=$restorationMarker
    DeviceStateDirectory='/data/local/tmp/mibox-acm-test-v3'
    Evidence=$evidenceDirectory
}
$result | ConvertTo-Json | Set-Content (Join-Path $evidenceDirectory 'result.json') -Encoding UTF8
$result | Format-List
if (-not ($sawReady -and $sawAck -and $adbRestored -and $sameBoot -and $restorationMarker)) { throw 'ACM test incomplete or device rebooted; inspect saved evidence' }
Write-Output 'MIBOX_USB_ACM_TEST_PASSED'
