$ErrorActionPreference='Stop'
$repo='F:\coding\otherPrj\mibox'
$evidence=Join-Path $repo ('artifacts/ram-boot/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-resume-hardware3')
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $repo 'scripts/RamBootProcess.ps1')
. (Join-Path $repo 'scripts/RamBootValidation.ps1')
$oldPath=Join-Path $repo 'artifacts/ram-boot/20261114-202635-053/result.json'
$old=Get-Content -Raw -LiteralPath $oldPath | ConvertFrom-Json
$hash='5f6a5654e5603c7abaeb9dca21996bc5a6e3bc0a83b650c8e0e347de100fdd55'
$proof=[ordered]@{Action='ResumeBoot';Candidate='Hardware3';StartedAt=(Get-Date).ToString('o');Stage='Preflight';ImageSHA256=$hash;DeviceAccessed=$false;FlashCommandSent=$false;LoaderRequestSent=$false;CustomBootVerified=$false;PreviousEvidence=$oldPath;AndroidBaseline=$old.AndroidBaseline;ControlTimeoutMilliseconds=10000;PriorFailedTransfer='artifacts/ram-boot/20261114-204540-498-resume-hardware3/result.json';ReadOnlyRecoveryProbe='artifacts/network-hdmi-audio/20261114-205417-603-loader-diagnostic/loader-readonly.json'}
function Save-Proof {$proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')}
function Script([string]$Name,[string]$File,[string]$Arguments,[int]$Seconds) {
    Run-Process $Name (Join-Path $PSHOME 'powershell.exe') ('-NoProfile -File "'+(Join-Path $repo ('scripts/'+$File))+'" '+$Arguments) $Seconds
}
function Adb([string]$Name,[string]$Arguments) {Run-Process $Name (Join-Path $repo 'phone-tools/platform-tools/adb.exe') $Arguments 10}
try {
    if($old.Stage -ne 'UploadAndVerify' -or $old.Candidate -ne 'Hardware2' -or $old.ImageSHA256 -cne '38ffab4483d5470091468a47a1f2397337f2cdb3f7858fe2e4cf015fdeb8afa1' -or
       $old.LocalImageVerified -ne $true -or $old.FlashCommandSent -ne $false -or $old.AndroidBaseline.BootCompleted -ne '1' -or
       $old.AndroidBaseline.Fingerprint -cne 'Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys' -or
       $old.AndroidBaseline.BootId -cne '527ddc8d-bf35-4dce-9cb2-db10ef5fae5d') {throw 'Interrupted run provenance mismatch'}
    $active=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -match '^"?[^\r\n]*powershell.exe"? -NoProfile -File "[^\r\n]*Test-MiboxLoaderRam.ps1"'})
    if($active.Count){throw 'Another RAM uploader is active'}
    $local=Script 'local-image-check' 'Test-MiboxLoaderRam.ps1' '-Action UploadAndBoot -Candidate Hardware3 -VerifyOnly' 30
    Assert-RamBootRecord ($local.Output | ConvertFrom-Json) Local $hash
    $proof.LocalImageVerified=$true
    $devices=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {$_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\' -and $_.Status -eq 'OK'})
    if($devices.Count -ne 1){throw 'Exactly one existing C003 loader required; no mode change requested'}
    $proof.LoaderInstance=$devices[0].InstanceId;$proof.DeviceAccessed=$true
    Copy-Item -LiteralPath (Join-Path $repo 'artifacts/ram-boot/20261114-202635-053/android-baseline.json') -Destination (Join-Path $evidence 'android-baseline.json')
    $proof.Stage='UploadAndVerify';Save-Proof
    $upload=Script 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' '-Action UploadAndBoot -Candidate Hardware3 -ControlTimeoutMilliseconds 10000' 3600
    $transfer=$upload.Output | ConvertFrom-Json
    Assert-RamBootRecord $transfer Transfer $hash
    $proof.Transfer=$transfer;$proof.Stage='ObserveCustomBoot';Save-Proof
    $observer=Script 'custom-observer' 'Observe-MiboxRamBoot.ps1' '-TimeoutSeconds 120' 210
    $observed=$observer.Output | ConvertFrom-Json
    Assert-RamBootRecord $observed Custom $hash $old.AndroidBaseline.BootId
    $pins=[ordered]@{init=@('/init','c9685fe4a4e6892a273917e0b82f77d0cd74320245d43ec413cea8b59b213c4b');mibox=@('/bin/mibox','e8fa69daba2bb78b42fdff17ca3819fe2bcf5afb007c129aad3384e0053adecf');helper=@('/sbin/mibox-hardware','1d21c17cfec18992a104e163180fea5b632ec06290b452e19a9b200504c379d3')}
    foreach($name in $pins.Keys) {
        $file=Join-Path $evidence ($name+'.elf')
        [void](Adb ('pull-'+$name) ('-s 248243005297 pull '+$pins[$name][0]+' "'+$file+'"'))
        $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -cne $pins[$name][1]){throw ('Executable hash mismatch: '+$name)}
        $proof[$name+'Sha256']=$actual
    }
    $customId=$observed.Proof.bootId.Output
    $ready=(Adb 'restart-ready' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if($ready -cne ('MIBOX_RESTART_READY boot_id='+$customId)){throw 'Restart channel not ready'}
    $proof.CustomBootId=$customId;$proof.CustomBootVerified=$true;$proof.Stage='Passed'
    Write-Output ('RESUME_BOOT_PASS: '+$evidence)
} catch {$proof.Failure=$_.Exception.Message;throw}
finally {$proof.FinishedAt=(Get-Date).ToString('o');Save-Proof}
