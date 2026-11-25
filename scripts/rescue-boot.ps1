# Start the pinned custom rescue image from an already reachable C003 loader.
# No Android query, software reboot, flash or environment command is issued.
param(
    [ValidateSet('Check','WaitAndBoot')][string]$Action='Check',
    [ValidateSet('Console','FailSafe','Loader','Slim','SlimKernelDev','SlimKernelDev2','SlimKernelDev3','SlimKernelDev4','SlimKernelDev5','SlimKernelDev6','SlimKernelDev7','SlimKernelDev8','SlimKernelDev9','SlimKernelDev10','SlimKernelDev11','SlimKernelDev12','SlimKernelDev13')][string]$Candidate='Console',
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
if($Candidate -eq 'Slim') {
    # Slim A3 image: FailSafe rootfs without package tools/RAM SSH, PID1 and
    # /bin/mibox with PERSIST-STOP; activates the persistent Alpine tree at boot.
    # Physically RAM-booted 2026-11-17 (artifacts/rescue-boot/20261117-202114-211).
    $hash='f11de99e04362e5cb6cb4c84aa077bc534613185ea98c3461e77d229e71e1505'
    $initHash='4d6dae1f9da50c63679c9a5c9446dc6f7282211dde4d9cef614796cdddf8c4e5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev') {
    # RAM-only test: the pinned 3.10.99 container kernel (stock DTB) with the
    # Slim rootfs; PID1 from the container-kernel-test feature build plus its
    # marker. Never written to flash. HDMI stays muted on C003 boots.
    $hash='7279a88a6b2755dbc44c903a312ce3efcc77d1295d3565faee9850108712c0c7'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev2') {
    # As SlimKernelDev, with kernel patch 0000 (stock MPT offset 2 MiB; stock
    # Ethernet clock/mode registers, pinctrl and PHY reset in probe).
    $hash='11b85b1fcb35edc9062f2227a9394dec29557ab741f5abb69483da52f49f560e'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev3') {
    # As SlimKernelDev2, with the Alpine tree bind-mounted onto itself (mount
    # namespaces work inside it) and fbhandoff accepting 3.10.99.
    $hash='6f500cfdc256517455d91568d1612dd93bff60a31b1ffb181766b86f3c031738'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev4') {
    # As SlimKernelDev3; the persistence stop unmounts every mount below the
    # tree, deepest first (dockerd leaves /var/lib/docker bound after exit).
    $hash='b11422d78b8e0cd54b565bd5dd61d065509cae20d4423c3ae45296d8dde0de76'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev5') {
    # As SlimKernelDev4, plus /sbin/mibox-docker: supervised dockerd in the
    # tree (opt-in /etc/mibox-docker.enabled), cgroup v1 mounts, legacy
    # iptables, graceful engine stop before the persistence stop.
    $hash='7f3fb6b1db84376bd8c666800197da164ab84006a040b6eb7902ef0d0ea4fec0'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev6') {
    # As SlimKernelDev5, with kernel patch 0002: a bridge created with an
    # address (docker0) gets its local fdb entry, so containers reach the host.
    $hash='ac5526de79281065b7c66bbf556e89d637906d13e94d4c7a24f8dbe185e16946'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev7') {
    # As SlimKernelDev6, with fbhandoff/fbstatus accepting the BGRA fb0 the
    # 3.10.99 BSP reports (owner saw correct colors, full 1080p after scaling).
    $hash='bccbad4ff8e7e104de544537ddc1d89ea07fced3c34645b92ae74ac6e0268b4a'
    $initHash='628b3453a92b66a17008b87e1e4d07f2bd4f32342d6757d351bf92015d363fc5'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev8') {
    # As SlimKernelDev7; PID1 starts dropbear without -s (password logins
    # allowed, -T 3) so a root password is the fallback if the PC is lost.
    $hash='0d549c0fd27a12fc42e4d11b8dfb1c3cfce4067bd9b3ef521d84c8543588d9a2'
    $initHash='5b5cfb5f7f79a6e56f15fae5afd262803f73ab518181cfd5cf11de863d076dde'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev9') {
    # As SlimKernelDev8; mibox-docker runs dockerd in a private mount namespace
    # with the tree moved over /, so docker exec lands in the container, not
    # in the RAM root.
    $hash='c3e952e88517f1cb49d37b166d5f2e573cf6bc36e9021ff6e49bcb4a46c6a36d'
    $initHash='5b5cfb5f7f79a6e56f15fae5afd262803f73ab518181cfd5cf11de863d076dde'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev10') {
    # As SlimKernelDev9; the HDMI status screen gains a SoC temperature card
    # (slim start switches SARADC channel 6 to the on-die sensor).
    $hash='760288f637c7f769dcad94a87a142fd3b1c7a60d159d143b5751b1f23df02ab6'
    $initHash='5b5cfb5f7f79a6e56f15fae5afd262803f73ab518181cfd5cf11de863d076dde'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev11') {
    $hash='d84d6ebf0018101e5ef8b713a1df390d595aa298ffefa3e5025cbf6893e395b3'
    $initHash='5b5cfb5f7f79a6e56f15fae5afd262803f73ab518181cfd5cf11de863d076dde'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev12') {
    # As SlimKernelDev11 (same kernel and DTB); mibox-netwatch restores the
    # static address and default route after an Ethernet down/up.
    $hash='772c22101c68440ee6bcf0280dd83d1b42ab30a684b42452be0a297c41c807ec'
    $initHash='5b5cfb5f7f79a6e56f15fae5afd262803f73ab518181cfd5cf11de863d076dde'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
}
if($Candidate -eq 'SlimKernelDev13') {
    # Dev12 plus the backported pids cgroup controller (kernel patch 0003);
    # mibox-docker also mounts the pids hierarchy.
    $hash='614861f672f6ef24aa1e1a803cb6ec4ddcecb173683a978ed06cbc837af5ef24'
    $initHash='5b5cfb5f7f79a6e56f15fae5afd262803f73ab518181cfd5cf11de863d076dde'
    $miboxHash='c7f2b1b1e8fc25e310540e991148282ca26cc38a7b3bf2af62e78eb05443b226'
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
