# A32-style orchestration using the Mi Box's verified RAM-only USB protocol.
param(
    [ValidateSet('Check','Boot','RoundTrip')][string]$Action = 'Check',
    [ValidateRange(60,7200)][int]$TransferTimeoutSeconds = 3600
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$evidence = Join-Path $repo ('artifacts/ram-boot/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence | Out-Null
$proof = [ordered]@{ Action = $Action; StartedAt = (Get-Date).ToString('o'); Stage = 'LocalCheck'
    ImageSHA256 = '5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa'
    DeviceAccessed = $false; LoaderRequestSent = $false; CustomBootVerified = $false
    AndroidReturnVerified = $false; FlashCommandSent = $false
    TransferDeadlineSeconds = $TransferTimeoutSeconds }
function Save-Proof {
    $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
}
function Run-Process([string]$Name, [string]$Executable, [string]$Arguments, [int]$DeadlineSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable; $start.Arguments = $Arguments
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $nextNotice = 30
        $timedOut = $false
        while (-not $process.WaitForExit(1000)) {
            if ($clock.Elapsed.TotalSeconds -ge $DeadlineSeconds) { $timedOut = $true; $process.Kill(); break }
            if ($clock.Elapsed.TotalSeconds -ge $nextNotice) {
                Write-Host ("{0}: {1}s elapsed" -f $Name, [int]$clock.Elapsed.TotalSeconds)
                $nextNotice += 30
            }
        }
        $process.WaitForExit()
        $result = [ordered]@{ Arguments = $Arguments; ExitCode = $process.ExitCode
            TimedOut = $timedOut; Output = $stdout.Result.Trim(); Error = $stderr.Result.Trim() }
        $result | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence ($Name + '.json'))
        if ($timedOut -or $result.ExitCode -ne 0) { throw "$Name failed; no automatic retry. Evidence: $evidence" }
        return $result
    } finally { $process.Dispose() }
}
function Run-Script([string]$Name, [string]$File, [string]$Arguments, [int]$DeadlineSeconds) {
    return Run-Process $Name (Join-Path $PSHOME 'powershell.exe') ("-NoProfile -File `"$(Join-Path $PSScriptRoot $File)`" $Arguments") $DeadlineSeconds
}
function Read-Adb([string]$Name, [string]$Arguments) {
    return Run-Process $Name (Join-Path $repo 'phone-tools/platform-tools/adb.exe') $Arguments 8
}
try {
    $local = Run-Script 'local-image-check' 'Test-MiboxLoaderRam.ps1' '-Action UploadAndBoot -Candidate Restart -VerifyOnly' 30
    $checked = $local.Output | ConvertFrom-Json
    if ($checked.UsbAccessed -ne $false -or $checked.Bytes -ne 8388608 -or $checked.Sha256 -cne $proof.ImageSHA256) {
        throw 'Local candidate validation did not match the pinned Restart image'
    }
    $proof.LocalImageVerified = $true
    if ($Action -eq 'Check') { $proof.Stage = 'LocalCheckPassed'; Save-Proof; Write-Output "CHECK_PASS (no device access): $evidence"; return }
    $proof.Stage = 'AndroidBaseline'; $proof.DeviceAccessed = $true; Save-Proof
    $fingerprint = (Read-Adb 'baseline-fingerprint' '-s 248243005297 shell getprop ro.build.fingerprint').Output
    $completed = (Read-Adb 'baseline-completed' '-s 248243005297 shell getprop sys.boot_completed').Output
    $bootId = (Read-Adb 'baseline-boot-id' '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id').Output
    if ($fingerprint -cne 'Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys' -or
        $completed -ne '1' -or $bootId -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
        throw 'Completed stock Android baseline required; no mode request sent'
    }
    if (-not (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_1B8E&PID_C003')) {
        throw 'Previously configured C003 driver record absent; no mode request sent'
    }
    $baseline = [ordered]@{ Fingerprint = $fingerprint; BootCompleted = $completed; BootId = $bootId }
    $baselinePath = Join-Path $evidence 'android-baseline.json'
    $baseline | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $baselinePath
    $proof.AndroidBaseline = $baseline
    $proof.Stage = 'LoaderTransition'; $proof.LoaderRequestSent = $true; Save-Proof
    [void](Read-Adb 'loader-request' '-s 248243005297 reboot usb_burner_reboot')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $found = $false
    while ($clock.Elapsed.TotalSeconds -lt 60) {
        $devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\' -and $_.Status -eq 'OK' })
        if ($devices.Count -gt 1) { throw 'Multiple C003 devices present; target is ambiguous' }
        if ($devices.Count -eq 1) { $found = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $found) { throw 'C003 did not appear; no reboot retry or reset sent' }
    $proof.Stage = 'UploadAndVerify'; Save-Proof
    $upload = Run-Script 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' '-Action UploadAndBoot -Candidate Restart' $TransferTimeoutSeconds
    $transfer = $upload.Output | ConvertFrom-Json
    if ($transfer.VerifiedBytes -ne 8388608 -or $transfer.VerifiedSha256 -cne $proof.ImageSHA256 -or
        -not $transfer.CommandAttempted -or $transfer.BulkMode) { throw 'Full verified RAM transfer not established' }
    $proof.Transfer = $transfer
    $proof.Stage = 'ObserveCustomBoot'; Save-Proof
    $observation = Run-Script 'custom-observer' 'Observe-MiboxRamBoot.ps1' '-TimeoutSeconds 120' 210
    $observed = $observation.Output | ConvertFrom-Json
    if (-not $observed.CustomOsMarkerObserved -or $observed.Proof.pid1.Output -ne 'init' -or
        $observed.Proof.bootId.Output -eq $bootId) { throw 'Independent custom boot identity not established' }
    foreach ($entry in @(@('/init','6ae13b3ed03864432edc4ca0f9ed8f9b46f6d6e6eeba690cf77dbbac0bc8e780'),
                         @('/bin/mibox','3e2d9a45aeff3d6b0bf727b1d1aadd31f8c776bf30fe62bf053ae3ac8ad240ce'))) {
        $label = if ($entry[0] -eq '/init') { 'init' } else { 'mibox' }
        $file = Join-Path $evidence ($label + '.elf')
        [void](Read-Adb ('pull-' + $label) ("-s 248243005297 pull $($entry[0]) `"$file`""))
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant() -cne $entry[1]) { throw 'Custom executable hash mismatch' }
    }
    $customId = $observed.Proof.bootId.Output
    $ready = (Read-Adb 'restart-readiness' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if ($ready -cne ('MIBOX_RESTART_READY boot_id=' + $customId)) { throw 'Custom restart interface not ready' }
    $proof.CustomBootVerified = $true; $proof.CustomBootId = $customId
    if ($Action -eq 'RoundTrip') {
        $proof.Stage = 'AndroidReturn'; Save-Proof
        [void](Run-Script 'android-return' 'Test-MiboxSoftwareReturn.ps1' ("-AndroidBaseline `"$baselinePath`" -TimeoutSeconds 180") 260)
        # Require the child verifier's structured result, not its console PASS text.
        $returnCall = Get-Content -Raw -LiteralPath (Join-Path $evidence 'android-return.json') | ConvertFrom-Json
        $match = [regex]::Match($returnCall.Output, '(?m)^Evidence: (.+)\r?$')
        if (-not $match.Success) { throw 'Return verifier evidence path absent' }
        $returnProof = Get-Content -Raw -LiteralPath (Join-Path $match.Groups[1].Value.Trim() 'result.json') | ConvertFrom-Json
        if ($returnProof.PhysicalAndroidReturnVerified -ne $true) { throw 'Independent Android return not verified' }
        $proof.AndroidReturnVerified = $true
    }
    $proof.Stage = 'Passed'
    Write-Output "RAM_BOOT_PASS ($Action): $evidence"
} catch {
    $proof.Failure = $_.Exception.Message
    throw
} finally { Save-Proof }
