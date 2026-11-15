param([ValidateSet('Check','RoundTrip')][string]$Action='Check',
    [ValidateSet('DockerKernel','DockerKernel2')][string]$Candidate='DockerKernel2')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/docker-runtime/physical-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$proof=[ordered]@{Action=$Action;Stage='LocalCheck';ImageSHA256='3d0be1a75f59e1ecd21459768b603cef8c3c769e0e31f69445d68cf34bf3f2dc';
    PayloadSHA256='33bba141e73e1a296f1c3bb425c8df2cd20593656275ecdfaa417dcc9824b880';
    KernelBootVerified=$false;OfflineContainerPassed=$false;SandboxCleaned=$false;
    AndroidReturnVerified=$false;FlashCommandSent=$false;PersistentStorageUsed=$false}
$proof.Candidate=$Candidate
$candidateDirectory='mibox-boot-candidate-docker'
if($Candidate -eq 'DockerKernel2') {
    $proof.ImageSHA256='13794e4423287cc12ea2b63bff22a937b156d70d54fb4141ba9342ea4b19c1fa'
    $candidateDirectory='mibox-boot-candidate-docker2'
}
function Save-Proof { $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $evidence 'result.json') }
function Child([string]$Name,[string]$File,[string]$Arguments,[int]$Deadline) {
    Run-Process $Name (Join-Path $PSHOME 'powershell.exe') ("-NoProfile -File `"$(Join-Path $PSScriptRoot $File)`" $Arguments") $Deadline
}
function Adb([string]$Name,[string]$Arguments,[int]$Deadline=15) {
    Run-Process $Name (Join-Path $repo 'phone-tools/platform-tools/adb.exe') ('-s 248243005297 '+$Arguments) $Deadline
}
try {
    $local=(Child 'local-check' 'Test-MiboxLoaderRam.ps1' "-Action UploadAndBoot -Candidate $Candidate -VerifyOnly" 30).Output | ConvertFrom-Json
    if($local.UsbAccessed -ne $false -or $local.Bytes -ne 8388608 -or $local.Sha256 -cne $proof.ImageSHA256) {throw 'Pinned local image check failed'}
    $manifest=Get-Content (Join-Path $repo ("target/$candidateDirectory/manifest.json")) -Raw | ConvertFrom-Json
    $payload=Join-Path $repo 'target/mibox-docker-experiment/payload.tar.gz'
    if((Get-FileHash -Algorithm SHA256 $payload).Hash.ToLowerInvariant() -cne $proof.PayloadSHA256 -or
       $manifest.image_sha256 -cne $proof.ImageSHA256 -or -not $manifest.stock_dtb_unchanged -or
       $manifest.uimage_sha256 -cne '9b3998fc759a34781787d3df5ac03d133ebf7089069dccdd44b42b7348d3cd99') {throw 'Candidate/payload/kernel pin mismatch'}
    Copy-Item (Join-Path $repo ("target/$candidateDirectory/manifest.json")) (Join-Path $evidence 'candidate-manifest.json')
    if($Action -eq 'Check') {$proof.Stage='LocalCheckPassed';Save-Proof;Write-Output "CHECK_PASS: $evidence";return}
    $identity=(Adb 'baseline' 'shell "getprop ro.build.fingerprint; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id"').Output.Replace("`r",'') -split "`n"
    if($identity.Count -ne 3 -or $identity[0] -cne 'Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys' -or $identity[1] -ne '1' -or
       $identity[2] -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'Completed stock Android required'}
    $baselinePath=Join-Path $evidence 'android-baseline.json'
    [ordered]@{Fingerprint=$identity[0];BootCompleted=$identity[1];BootId=$identity[2]} | ConvertTo-Json | Set-Content -Encoding UTF8 $baselinePath
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
    $transfer=(Child 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' "-Action UploadAndBoot -Candidate $Candidate -ControlTimeoutMilliseconds 10000" 3600).Output | ConvertFrom-Json
    if($transfer.VerifiedBytes -ne 8388608 -or $transfer.VerifiedSha256 -cne $proof.ImageSHA256 -or -not $transfer.CommandAttempted) {throw 'Transfer proof incomplete'}
    $proof.Transfer=$transfer;$proof.Stage='ObserveBoot';Save-Proof
    [void](Child 'boot-observer' 'Observe-MiboxRamBoot.ps1' '-TimeoutSeconds 120' 210)
    $bootId=(Adb 'custom-boot-id' 'shell cat /proc/sys/kernel/random/boot_id').Output
    $release=(Adb 'kernel-release' 'shell cat /proc/sys/kernel/osrelease').Output
    if($release -cne '3.10.99' -or $bootId -eq $identity[2] -or $bootId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'New kernel/boot identity not established'}
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
    if($configHash -cne $manifest.build_config_sha256) {throw 'Running embedded config differs from build'}
    $proof.RuntimeConfigSHA256=$configHash;$proof.KernelBootVerified=$true;$proof.CustomBootId=$bootId
    $before=(Adb 'mounts-before' 'shell cat /proc/mounts').Output
    $proof.Stage='StageRamPayload';Save-Proof
    [void](Adb 'push-payload' ("push `"$payload`" /tmp/mibox-docker-payload.upload") 180)
    $readback=Join-Path $repo 'target/mibox-docker-experiment/payload-readback.tar.gz'
    [void](Adb 'pull-payload' ("pull /tmp/mibox-docker-payload.upload `"$readback`"") 180)
    if((Get-FileHash -Algorithm SHA256 $readback).Hash.ToLowerInvariant() -cne $proof.PayloadSHA256) {throw 'Payload readback mismatch'}
    $proof.PayloadReadbackVerified=$true
    [void](Adb 'release-payload' 'shell /bin/busybox mv /tmp/mibox-docker-payload.upload /tmp/mibox-docker-payload.ready')
    $proof.Stage='OfflineContainer';Save-Proof
    $timer.Restart();$sequence=0;$log=''
    while($timer.Elapsed.TotalSeconds -lt 330) {
        $sequence++
        $log=(Adb ('experiment-log-'+$sequence) 'shell cat /tmp/mibox-docker-experiment.log').Output
        if($log -match 'MIBOX_DOCKER_BOOTSTRAP_DONE') {break}
        Start-Sleep -Seconds 5
    }
    $log | Set-Content -Encoding UTF8 (Join-Path $evidence 'experiment.log')
    $proof.OfflineContainerPassed=$log -match '(?m)^MIBOX_DOCKER_OFFLINE_TEST_PASS\s*$' -and $log -match '(?m)^MIBOX_DOCKER_EXPERIMENT_EXIT=0\s*$'
    $after=(Adb 'mounts-after' 'shell cat /proc/mounts').Output
    $processes=(Adb 'processes-after' 'shell /bin/busybox ps -o pid,comm').Output
    $proof.SandboxCleaned=$log -match 'MIBOX_DOCKER_BOOTSTRAP_DONE' -and $before -ceq $after -and $processes -notmatch '(?m)\s(dockerd|containerd|runc|mibox-docker-sa)\s*$'
    $proof.Stage='ReturnToAndroid';Save-Proof
    [void](Child 'android-return' 'Test-MiboxSoftwareReturn.ps1' ("-Candidate $Candidate -AndroidBaseline `"$baselinePath`"") 240)
    $proof.AndroidReturnVerified=$true;$proof.Stage='Complete';Save-Proof
    if(-not $proof.OfflineContainerPassed -or -not $proof.SandboxCleaned) {throw 'Returned to Android, but offline engine/cleanup gate failed; inspect evidence'}
    Write-Output "PASS: physical offline Docker container and Android return: $evidence"
} catch {
    $proof.Failure=$_.Exception.Message;Save-Proof;throw
}
