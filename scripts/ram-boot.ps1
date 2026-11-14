# A32-style orchestration using the Mi Box's verified RAM-only USB protocol.
param(
    [ValidateSet('Check','Boot','RoundTrip')][string]$Action = 'Check',
    [ValidateSet('Restart','Health')][string]$Candidate = 'Restart',
    [ValidateRange(60,7200)][int]$TransferTimeoutSeconds = 3600
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'RamBootValidation.ps1')
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$evidence = Join-Path $repo ('artifacts/ram-boot/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence | Out-Null
$proof = [ordered]@{ Action = $Action; StartedAt = (Get-Date).ToString('o'); Stage = 'LocalCheck'
    ImageSHA256 = '5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa'
    DeviceAccessed = $false; LoaderRequestSent = $false; CustomBootVerified = $false
    AndroidReturnVerified = $false; FlashCommandSent = $false
    TransferDeadlineSeconds = $TransferTimeoutSeconds }
$proof.Candidate=$Candidate
$initHash='6ae13b3ed03864432edc4ca0f9ed8f9b46f6d6e6eeba690cf77dbbac0bc8e780'
$toolHash='3e2d9a45aeff3d6b0bf727b1d1aadd31f8c776bf30fe62bf053ae3ac8ad240ce'
if($Candidate -eq 'Health') {
    $proof.ImageSHA256='2788822cb79c3808ef6f4bb067fc4b57a033319c5fa0e93ecaec6874c8879bc3'
    $initHash='8c2f9bcd4c5c26585062fbb5f44c7aeadbbe975217d28ab939f65173cb61cb6a'
    $toolHash='2e4f1dfd8f28c0bf52323a9e65abf314e1e1705505414cc7cc25fcdf99128512'
}
function Save-Proof {
    $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
}
function Run-Script([string]$Name, [string]$File, [string]$Arguments, [int]$DeadlineSeconds) {
    return Run-Process $Name (Join-Path $PSHOME 'powershell.exe') ("-NoProfile -File `"$(Join-Path $PSScriptRoot $File)`" $Arguments") $DeadlineSeconds
}
function Read-Adb([string]$Name, [string]$Arguments) {
    return Run-Process $Name (Join-Path $repo 'phone-tools/platform-tools/adb.exe') $Arguments 8
}
try {
    $provenance = foreach ($name in @('ram-boot.ps1','RamBootProcess.ps1','RamBootValidation.ps1','Test-MiboxLoaderRam.ps1',
                                     'Observe-MiboxRamBoot.ps1','Test-MiboxSoftwareReturn.ps1')) {
        $path = Join-Path $PSScriptRoot $name
        [pscustomobject]@{ File = $name; SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }
    }
    $provenance | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'orchestrator-provenance.json')
    $local = Run-Script 'local-image-check' 'Test-MiboxLoaderRam.ps1' "-Action UploadAndBoot -Candidate $Candidate -VerifyOnly" 30
    $checked = $local.Output | ConvertFrom-Json
    Assert-RamBootRecord $checked Local $proof.ImageSHA256
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
    $upload = Run-Script 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' "-Action UploadAndBoot -Candidate $Candidate" $TransferTimeoutSeconds
    $transfer = $upload.Output | ConvertFrom-Json
    Assert-RamBootRecord $transfer Transfer $proof.ImageSHA256
    $proof.Transfer = $transfer
    $proof.Stage = 'ObserveCustomBoot'; Save-Proof
    $observation = Run-Script 'custom-observer' 'Observe-MiboxRamBoot.ps1' '-TimeoutSeconds 120' 210
    $observed = $observation.Output | ConvertFrom-Json
    Assert-RamBootRecord $observed Custom $proof.ImageSHA256 $bootId
    foreach ($entry in @(@('/init',$initHash), @('/bin/mibox',$toolHash))) {
        $label = if ($entry[0] -eq '/init') { 'init' } else { 'mibox' }
        $file = Join-Path $evidence ($label + '.elf')
        [void](Read-Adb ('pull-' + $label) ("-s 248243005297 pull $($entry[0]) `"$file`""))
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant() -cne $entry[1]) { throw 'Custom executable hash mismatch' }
    }
    $customId = $observed.Proof.bootId.Output
    if($Candidate -eq 'Health') {
        $health=(Read-Adb 'custom-health' '-s 248243005297 shell "/bin/mibox health; result=$?; echo MIBOX_HEALTH_EXIT=$result"').Output.Replace("`r",'')
        $lines=@($health -split "`n")
        if($lines.Count -ne 9 -or $lines[0] -cne 'MIBOX_HEALTH_SNAPSHOT_V1' -or
            $lines[1] -cne ('boot_id='+$customId) -or $lines[2] -cnotmatch '^uptime_seconds=[0-9]+\.[0-9]+$' -or
            $lines[3] -cne 'pid1=init' -or $lines[4] -cne 'root_fstype=rootfs' -or
            $lines[5] -cne 'mem_total_kib=877072' -or $lines[6] -cnotmatch '^mem_free_kib=[0-9]+$' -or
            $lines[7] -cne 'mem_available_kib=UNKNOWN' -or $lines[8] -cne 'MIBOX_HEALTH_EXIT=0') {
            throw 'Physical health snapshot identity/counters/exit mismatch'
        }
        $proof.HealthVerified=$true
    }
    $ready = (Read-Adb 'restart-readiness' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if ($ready -cne ('MIBOX_RESTART_READY boot_id=' + $customId)) { throw 'Custom restart interface not ready' }
    $proof.CustomBootVerified = $true; $proof.CustomBootId = $customId
    if ($Action -eq 'RoundTrip') {
        $proof.Stage = 'AndroidReturn'; Save-Proof
        [void](Run-Script 'android-return' 'Test-MiboxSoftwareReturn.ps1' ("-AndroidBaseline `"$baselinePath`" -TimeoutSeconds 180 -Candidate $Candidate") 260)
        # Require the child verifier's structured result, not its console PASS text.
        $returnCall = Get-Content -Raw -LiteralPath (Join-Path $evidence 'android-return.json') | ConvertFrom-Json
        $match = [regex]::Match($returnCall.Output, '(?m)^Evidence: (.+)\r?$')
        if (-not $match.Success) { throw 'Return verifier evidence path absent' }
        $returnProof = Get-Content -Raw -LiteralPath (Join-Path $match.Groups[1].Value.Trim() 'result.json') | ConvertFrom-Json
        Assert-RamBootRecord $returnProof Return
        $proof.AndroidReturnVerified = $true
    }
    $proof.Stage = 'Passed'
    Write-Output "RAM_BOOT_PASS ($Action): $evidence"
} catch {
    $proof.Failure = $_.Exception.Message
    throw
} finally { $proof.FinishedAt = (Get-Date).ToString('o'); Save-Proof }
