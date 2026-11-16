# Start the pinned custom rescue image from an already reachable C003 loader.
# No Android query, software reboot, flash or environment command is issued.
param(
    [ValidateSet('Check','WaitAndBoot')][string]$Action='Check',
    [ValidateSet('Console','FailSafe','Loader')][string]$Candidate='Console',
    [ValidateRange(1,600)][int]$WaitSeconds=120,
    [ValidateRange(60,7200)][int]$TransferTimeoutSeconds=3600,
    # Bulk OUT upload verified by loader crc32 (see Test-MiboxLoaderRam.ps1).
    [switch]$Bulk
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/rescue-boot/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
. (Join-Path $PSScriptRoot 'RamBootValidation.ps1')
$hash='4629deefd4e5e0f1902a54158ef01c7ad67156ef87946fb6d87c7070ba5da7c0'
$initHash='9333195a11b758f7531547008b927849da228ceddb41398d3d2b8bca25258438'
$miboxHash='e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07'
if($Candidate -eq 'FailSafe') {
    # Pinned Console rootfs with only /init replaced by the fail-safe PID1.
    $hash='f5e9cd6b8677504429340dcc1f51261fd10108020366461c0cede198afcd6d93'
    $initHash='a24de13aecd55829483099ab921fdd3651a481656e404b68874017c99267680c'
}
if($Candidate -eq 'Loader') {
    # FailSafe-style Console rootfs with init and /bin/mibox from the loader-restart feature build.
    $hash='9c45436205964fabb2f2a113a7b65be524a3f1acde0933f2c5a4b1b460c8b58c'
    $initHash='9b633cdefa3747a2fdfcf7e30eac5c6df0675734569ef51d77813a98d538194c'
    $miboxHash='d182d76d308acbc1f372e1ac218fa7508ecbe87ebf475ac4d8f6f4f39ee33a8e'
}
$proof=[ordered]@{Action=$Action;Stage='LocalCheck';Candidate=$Candidate;ImageSHA256=$hash;BulkUpload=[bool]$Bulk
    DeviceAccessed=$false;LoaderRequestSent=$false;FlashCommandSent=$false
    EnvironmentWriteSent=$false;CustomBootVerified=$false;IndependentColdEntryVerified=$false
    EntryOrigin='UNKNOWN: supplied externally; this launcher does not establish a cold-start trigger'
    StartedAt=[DateTime]::UtcNow.ToString('o');Evidence=$evidence}
function Call-Script([string]$Name,[string]$File,[string]$Arguments,[int]$Seconds) {
    Run-Process $Name (Join-Path $PSHOME 'powershell.exe') (
        '-NoProfile -File "'+(Join-Path $PSScriptRoot $File)+'" '+$Arguments) $Seconds
}
try {
    $sources=@('rescue-boot.ps1','RamBootProcess.ps1','RamBootValidation.ps1',
        'Probe-MiboxUsbLoader.ps1','Test-MiboxLoaderRam.ps1','Observe-MiboxRamBoot.ps1')
    @(foreach($file in $sources) {
        @{File=$file;SHA256=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot $file)).Hash.ToLowerInvariant()}
    }) | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'provenance.json')
    $local=Call-Script 'local-check' 'Test-MiboxLoaderRam.ps1' "-Action UploadAndBoot -Candidate $Candidate -VerifyOnly" 30
    Assert-RamBootRecord ($local.Output | ConvertFrom-Json) Local $hash
    if($Action -eq 'Check') {
        $proof.Stage='LocalCheckPassed'
        Write-Output "RESCUE_LOCAL_CHECK_PASS (no device access): $evidence"
        return
    }
    $proof.Stage='WaitingForLoader';$proof.DeviceAccessed=$true
    Write-Host "RESCUE_WAITING_FOR_C003: $evidence"
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $found=$false
    while($clock.Elapsed.TotalSeconds -lt $WaitSeconds) {
        # Whole USB device nodes only; exclude composite interface duplicates.
        $nodes=@(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object {$_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\'})
        @{Utc=[DateTime]::UtcNow.ToString('o');Devices=$nodes} | ConvertTo-Json -Depth 5 -Compress |
            Add-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'usb-events.jsonl')
        if($nodes.Count -gt 1){throw 'Multiple C003 devices; refuse ambiguous target'}
        if($nodes.Count -eq 1) {
            if($nodes[0].Status -ne 'OK'){throw 'C003 present but driver is not ready'}
            $found=$true;break
        }
        Start-Sleep -Milliseconds 500
    }
    if(-not $found){throw 'No C003 loader observed; no reboot or automatic retry sent'}
    $proof.Stage='IdentifyLoader'
    $identify=(Call-Script 'loader-identify' 'Probe-MiboxUsbLoader.ps1' '-Identify' 20).Output | ConvertFrom-Json
    if($identify.Found -isnot [bool] -or -not $identify.Found -or
       $identify.VidPid -cne '1B8E:C003' -or $identify.IdentifyHex -cne '00-08-00-10') {
        throw 'Unverified loader identity; no RAM upload attempted'
    }
    $proof.LoaderIdentity=$identify
    $adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
    $prior=Run-Process 'pre-upload-adb' $adb 'devices -l' 8
    if($prior.Output -match '(?m)^248243005297\s+') {
        throw 'Target ADB is already present alongside C003; refuse ambiguous boot evidence'
    }
    $proof.Stage='UploadAndVerify'
    $transfer=(Call-Script 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' (
        "-Action UploadAndBoot -Candidate $Candidate -ControlTimeoutMilliseconds 10000"+$(if($Bulk){' -Bulk'}else{''})) $TransferTimeoutSeconds).Output | ConvertFrom-Json
    Assert-RamBootRecord $transfer Transfer $hash
    $proof.Transfer=$transfer
    $proof.Stage='VerifyCustomRuntime'
    $observed=(Call-Script 'custom-observer' 'Observe-MiboxRamBoot.ps1' '-TimeoutSeconds 120' 210).Output | ConvertFrom-Json
    Assert-RamBootRecord $observed Custom $hash
    foreach($name in @('osRelease','pid1','bootId')) {
        if($observed.Proof.$name.OutputComplete -isnot [bool] -or -not $observed.Proof.$name.OutputComplete) {
            throw 'Incomplete runtime identity output'
        }
    }
    foreach($item in @(@('/init',$initHash,'init'),
                       @('/bin/mibox',$miboxHash,'mibox'))) {
        $output=Join-Path $evidence ($item[2]+'.elf')
        [void](Run-Process ('pull-'+$item[2]) $adb ('-s 248243005297 pull '+$item[0]+' "'+$output+'"') 20)
        $actualHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()
        if($actualHash -cne $item[1]) {
            throw ('Rescue runtime executable hash mismatch for '+$item[0]+': '+$actualHash)
        }
    }
    $proof.CustomBootId=$observed.Proof.bootId.Output
    $proof.CustomBootVerified=$true;$proof.Stage='RamRescueLoaded'
    Write-Output "RAM_RESCUE_LOADED (cold-start trigger not verified): $evidence"
} catch {
    $proof.Failure=$_.Exception.Message
    throw
} finally {
    $proof.FinishedAt=[DateTime]::UtcNow.ToString('o')
    $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
}
