param([ValidateSet('Check','RoundTrip')][string]$Action='Check')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/kernel-meson6/physical-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$proof=[ordered]@{Action=$Action;Stage='LocalCheck';ImageSHA256='fb1333d9d36c92577ef17643590f67cea596e7d76df33ff8238aa7fcb192f6a6'
    DeviceAccessed=$false;KernelBootVerified=$false;PrimitiveTestsPassed=$false;AndroidReturnVerified=$false;FlashCommandSent=$false}
function Save-Proof { $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $evidence 'result.json') }
function Child([string]$Name,[string]$File,[string]$Arguments,[int]$Deadline) {
    Run-Process $Name (Join-Path $PSHOME 'powershell.exe') ("-NoProfile -File `"$(Join-Path $PSScriptRoot $File)`" $Arguments") $Deadline
}
function Adb([string]$Name,[string]$Arguments) {
    Run-Process $Name (Join-Path $repo 'phone-tools/platform-tools/adb.exe') ('-s 248243005297 '+$Arguments) 10
}
try {
    $local=(Child 'local-check' 'Test-MiboxLoaderRam.ps1' '-Action UploadAndBoot -Candidate ContainerKernel2 -VerifyOnly' 30).Output | ConvertFrom-Json
    if($local.UsbAccessed -ne $false -or $local.Bytes -ne 8388608 -or $local.Sha256 -cne $proof.ImageSHA256) {throw 'Pinned local check failed'}
    $manifest=Get-Content (Join-Path $repo 'target/mibox-boot-candidate-kernel2/manifest.json') -Raw | ConvertFrom-Json
    if($manifest.image_sha256 -cne $proof.ImageSHA256 -or -not $manifest.stock_dtb_unchanged) {throw 'Candidate manifest mismatch'}
    Copy-Item (Join-Path $repo 'target/mibox-boot-candidate-kernel2/manifest.json') (Join-Path $evidence 'candidate-manifest.json')
    if($Action -eq 'Check') {$proof.Stage='LocalCheckPassed';Save-Proof;Write-Output "CHECK_PASS: $evidence";return}
    $proof.DeviceAccessed=$true;$proof.Stage='AndroidBaseline';Save-Proof
    $identity=(Adb 'baseline' 'shell "getprop ro.build.fingerprint; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id"').Output.Replace("`r",'') -split "`n"
    if($identity.Count -ne 3 -or $identity[0] -cne 'Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys' -or $identity[1] -ne '1' -or
       $identity[2] -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'Completed stock Android required'}
    $baselinePath=Join-Path $evidence 'android-baseline.json'
    [ordered]@{Fingerprint=$identity[0];BootCompleted=$identity[1];BootId=$identity[2]} | ConvertTo-Json | Set-Content -Encoding UTF8 $baselinePath
    $proof.AndroidBaselineBootId=$identity[2]
    $proof.Stage='LoaderTransition';Save-Proof
    [void](Adb 'loader-request' 'reboot usb_burner_reboot')
    $timer=[Diagnostics.Stopwatch]::StartNew();$found=$false
    while($timer.Elapsed.TotalSeconds -lt 60) {
        $devices=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {$_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\' -and $_.Status -eq 'OK'})
        if($devices.Count -gt 1) {throw 'Multiple loader devices'}
        if($devices.Count -eq 1) {$found=$true;break}
        Start-Sleep -Seconds 2
    }
    if(-not $found) {throw 'Loader did not appear; no retry sent'}
    $proof.Stage='UploadAndVerify';Save-Proof
    $transfer=(Child 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' '-Action UploadAndBoot -Candidate ContainerKernel2 -ControlTimeoutMilliseconds 10000' 3600).Output | ConvertFrom-Json
    if($transfer.VerifiedBytes -ne 8388608 -or $transfer.VerifiedSha256 -cne $proof.ImageSHA256 -or -not $transfer.CommandAttempted) {throw 'Transfer proof incomplete'}
    $proof.Transfer=$transfer;$proof.Stage='ObserveBoot';Save-Proof
    $observed=(Child 'boot-observer' 'Observe-MiboxRamBoot.ps1' '-TimeoutSeconds 120' 210).Output | ConvertFrom-Json
    $bootId=(Adb 'custom-boot-id' 'shell cat /proc/sys/kernel/random/boot_id').Output
    $release=(Adb 'kernel-release' 'shell cat /proc/sys/kernel/osrelease').Output
    if($release -cne $manifest.kernel_release -or $bootId -eq $identity[2] -or $bootId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'New kernel/boot identity not established'}
    foreach($entry in @(@('/init','e77771fc585ebf0ea0be44c8f319179e77e728146c7b2b0916626bdfed52c2d2','init.elf'),
                       @('/bin/mibox','e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07','mibox.elf'))) {
        $path=Join-Path $evidence $entry[2]
        [void](Adb ('pull-'+$entry[2]) ("pull $($entry[0]) `"$path`""))
        if((Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() -cne $entry[1]) {throw 'Custom binary hash mismatch'}
    }
    $configPath=Join-Path $evidence 'config.gz'
    [void](Adb 'pull-config' ("pull /proc/config.gz `"$configPath`""))
    $stream=[IO.Compression.GzipStream]::new([IO.File]::OpenRead($configPath),[IO.Compression.CompressionMode]::Decompress)
    $plain=[IO.MemoryStream]::new()
    try {$stream.CopyTo($plain);$bytes=$plain.ToArray()} finally {$stream.Dispose();$plain.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$configHash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
    if($configHash -cne $manifest.build_config_sha256) {throw 'Running embedded config differs from built config'}
    $proof.RuntimeConfigSHA256=$configHash;$proof.KernelBootVerified=$true;$proof.CustomBootId=$bootId
    $diagnostic=(Adb 'kernel-selftest' 'shell cat /tmp/mibox-kernel-selftest.txt').Output
    $proof.PrimitiveTestsPassed=$diagnostic -cmatch '(?m)^MIBOX_KERNEL_SELFTEST_PASS\s*$' -and $diagnostic -cnotmatch '=FAIL'
    [void](Adb 'runtime-mounts' 'shell cat /proc/mounts')
    [void](Adb 'runtime-memory' 'shell cat /proc/iomem')
    $proof.Stage='ReturnToAndroid';Save-Proof
    [void](Child 'android-return' 'Test-MiboxSoftwareReturn.ps1' ("-Candidate ContainerKernel2 -AndroidBaseline `"$baselinePath`"") 240)
    $proof.AndroidReturnVerified=$true;$proof.Stage='Complete';Save-Proof
    if(-not $proof.PrimitiveTestsPassed) {throw 'Kernel booted and returned, but primitive diagnostics did not pass'}
    Write-Output "PASS: new kernel, embedded config, container primitives and Android return: $evidence"
} catch {
    $proof.Failure=$_.Exception.Message;Save-Proof;throw
}
