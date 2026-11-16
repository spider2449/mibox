# Physical PID1 fail-safe test: from a reachable C003 loader, RAM-boot one
# fault-injected candidate and require that it restarts back into C003 by itself
# through the installed preboot USB window. RAM only: no flash, env or Android command.
param(
    [Parameter(Mandatory=$true)][ValidateSet('Panic','Usb','Hang','KPanic')][string]$Fault,
    [ValidateRange(1,600)][int]$WaitSeconds=120,
    [ValidateRange(60,7200)][int]$TransferTimeoutSeconds=3600,
    [ValidateRange(60,900)][int]$ObserveSeconds=300,
    # Bulk OUT upload verified by loader crc32 (8 s instead of ~22 min).
    [switch]$Bulk
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/fail-safe/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$Fault.ToLowerInvariant())
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
. (Join-Path $PSScriptRoot 'RamBootValidation.ps1')
$candidate='Fault'+$Fault
$hash=@{Panic='426731f53fccc0e76a402396b655ca85d1ba21178679dfdd3e4cb1b3afc63a0a'
        Usb='97a9b47bc975eb79e3c1c8355780aa6f5c5d0877974097c7c3c5a10a1e84b987'
        Hang='987851820bbe33d3aaef9668ed56f8cbdc4431b9c0afbaf78aaa0a1ffac8130b'
        KPanic='e1a698204599c9cf5e407604099646914e20cd5e771911de3bccc52572c6fdb4'}[$Fault]
# Seconds from bootm to C003 re-entry. Hang must outlive the 60 s setup deadline.
# KPanic: PID1 exits, the kernel panics and must restart after kernel.panic=20 s.
$window=@{Panic=@(0,60);Usb=@(0,60);Hang=@(60,180);KPanic=@(25,120)}[$Fault]
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$proof=[ordered]@{Fault=$Fault;Candidate=$candidate;ImageSHA256=$hash;Stage='LocalCheck';BulkUpload=[bool]$Bulk
    ExpectedReentrySeconds=$window;DeviceAccessed=$false;FlashCommandSent=$false
    EnvironmentWriteSent=$false;AndroidCommandSent=$false;FailSafeVerified=$false
    StartedAt=[DateTime]::UtcNow.ToString('o');Evidence=$evidence}
function Call-Script([string]$Name,[string]$File,[string]$Arguments,[int]$Seconds) {
    Run-Process $Name (Join-Path $PSHOME 'powershell.exe') (
        '-NoProfile -File "'+(Join-Path $PSScriptRoot $File)+'" '+$Arguments) $Seconds
}
function Get-Loader {
    $nodes=@(Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object {$_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\'})
    if($nodes.Count -gt 1){throw 'Multiple C003 devices; refuse ambiguous target'}
    return $nodes
}
function Assert-Loader([string]$Name) {
    $identify=(Call-Script $Name 'Probe-MiboxUsbLoader.ps1' '-Identify' 20).Output | ConvertFrom-Json
    if($identify.Found -isnot [bool] -or -not $identify.Found -or
       $identify.VidPid -cne '1B8E:C003' -or $identify.IdentifyHex -cne '00-08-00-10') {
        throw 'Unverified loader identity'
    }
    return $identify
}
try {
    $local=Call-Script 'local-check' 'Test-MiboxLoaderRam.ps1' "-Action UploadAndBoot -Candidate $candidate -VerifyOnly" 30
    Assert-RamBootRecord ($local.Output | ConvertFrom-Json) Local $hash
    $proof.Stage='WaitingForLoader';$proof.DeviceAccessed=$true
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        # @() keeps a single CimInstance as an array; a bare one has no Count.
        $nodes=@(Get-Loader)
        if($nodes.Count -eq 1 -and $nodes[0].Status -eq 'OK'){break}
        Start-Sleep -Milliseconds 500
    } while($clock.Elapsed.TotalSeconds -lt $WaitSeconds)
    if($nodes.Count -ne 1 -or $nodes[0].Status -ne 'OK'){throw 'No ready C003 loader; nothing sent'}
    $proof.LoaderBefore=Assert-Loader 'loader-identify-before'
    if((Run-Process 'pre-upload-adb' $adb 'devices -l' 8).Output -match '(?m)^248243005297\s+') {
        throw 'Target ADB present alongside C003; refuse ambiguous evidence'
    }
    $proof.Stage='UploadAndBoot'
    $transfer=(Call-Script 'upload-and-boot' 'Test-MiboxLoaderRam.ps1' (
        "-Action UploadAndBoot -Candidate $candidate -ControlTimeoutMilliseconds 10000"+$(if($Bulk){' -Bulk'}else{''})) $TransferTimeoutSeconds).Output | ConvertFrom-Json
    Assert-RamBootRecord $transfer Transfer $hash
    $proof.Transfer=$transfer
    $proof.Stage='ObserveRestart'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $left=$null;$returned=$null;$adbSeen=$false;$last=''
    while($clock.Elapsed.TotalSeconds -lt $ObserveSeconds) {
        $nodes=@(Get-Loader)
        $present=$nodes.Count -eq 1 -and $nodes[0].Status -eq 'OK'
        try {
            $devices=Run-Process 'adb-poll' $adb 'devices -l' 5
            if($devices.Output -match '(?m)^248243005297\s+'){$adbSeen=$true}
        } catch {
            # A failed adb query is not evidence either way; the loader state decides.
        }
        $state="loader=$present adb=$adbSeen"
        if($state -ne $last) {
            @{Elapsed=$clock.Elapsed.TotalSeconds;Utc=[DateTime]::UtcNow.ToString('o');Loader=$present;TargetAdb=$adbSeen} |
                ConvertTo-Json -Compress | Add-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'events.jsonl')
            $last=$state
        }
        if(-not $present -and $null -eq $left){$left=$clock.Elapsed.TotalSeconds}
        if($present -and $null -ne $left){$returned=$clock.Elapsed.TotalSeconds;break}
        Start-Sleep -Milliseconds 500
    }
    $proof.LoaderLeftSeconds=$left;$proof.LoaderReturnedSeconds=$returned;$proof.TargetAdbSeen=$adbSeen
    if($null -eq $left){throw 'C003 never disappeared after bootm'}
    if($null -eq $returned){throw "No C003 re-entry within $ObserveSeconds s; power-cycle manually, no retry sent"}
    if($adbSeen){throw 'Fault image exposed target ADB; fault was not effective'}
    if($returned -lt $window[0] -or $returned -gt $window[1]){throw "Re-entry after $returned s is outside $($window -join '-') s"}
    $proof.LoaderAfter=Assert-Loader 'loader-identify-after'
    $proof.FailSafeVerified=$true;$proof.Stage='Passed'
    Write-Output "FAIL_SAFE_PASS ($Fault, C003 re-entry after $([math]::Round($returned,1)) s): $evidence"
} catch {
    $proof.Failure=$_.Exception.Message
    throw
} finally {
    $proof.FinishedAt=[DateTime]::UtcNow.ToString('o')
    $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
}
