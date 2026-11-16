# Physical test of the PID1 LOADER request (feature loader-restart). Precondition:
# the verified Loader candidate is running (rescue-boot.ps1 -Candidate Loader).
# Sends `mibox reboot-loader` for the current boot ID and requires C003 to appear.
# With the preboot window installed, C003 also follows a normal restart, so this
# proves the custom-system request path, not the 0x09090909 loader branch alone.
# RAM only: no flash, env or Android command.
param(
    [ValidateRange(30,600)][int]$ObserveSeconds=120
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/loader-restart/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$serial='248243005297'
$userland='d182d76d308acbc1f372e1ac218fa7508ecbe87ebf475ac4d8f6f4f39ee33a8e'
$proof=[ordered]@{Stage='Identify';FlashCommandSent=$false;EnvironmentWriteSent=$false
    AndroidCommandSent=$false;LoaderRestartVerified=$false
    PrebootWindowInstalled='assumed (see docs/mibox-independent-rescue.md); not distinguishable here'
    StartedAt=[DateTime]::UtcNow.ToString('o');Evidence=$evidence}
function Get-Loader {
    $nodes=@(Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object {$_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\'})
    if($nodes.Count -gt 1){throw 'Multiple C003 devices; refuse ambiguous target'}
    return $nodes
}
try {
    if(@(Get-Loader).Count -ne 0){throw 'C003 already present; refuse ambiguous evidence'}
    $os=(Run-Process 'os-release' $adb "-s $serial shell cat /etc/os-release" 8).Output
    if($os -notmatch '(?m)^ID=mibox-custom\s*$'){throw 'Target is not the custom system'}
    $pull=Join-Path $evidence 'mibox.elf'
    [void](Run-Process 'pull-mibox' $adb "-s $serial pull /bin/mibox `"$pull`"" 20)
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $pull).Hash.ToLowerInvariant() -cne $userland) {
        throw 'Running /bin/mibox is not the Loader candidate userland'
    }
    $bootId=((Run-Process 'boot-id' $adb "-s $serial shell cat /proc/sys/kernel/random/boot_id" 8).Output).Trim()
    if($bootId -notmatch '^[0-9a-f-]{36}$'){throw 'Invalid boot ID'}
    $proof.BootId=$bootId
    # A stale ID must be refused. This adbd reports exit code 0 regardless, so
    # judge by the client's output (server-side stale refusal is QEMU-tested).
    $stale=(Run-Process 'stale-request' $adb "-s $serial shell /bin/mibox reboot-loader --boot-id 00000000-0000-0000-0000-000000000000" 8).Output
    if($stale -match 'ACCEPTED' -or $stale -notmatch 'boot ID does not match current boot'){throw 'Stale boot ID was not refused'}
    if(@(Get-Loader).Count -ne 0){throw 'C003 appeared after the stale request'}
    $proof.StaleRejected=$true
    $proof.Stage='Request'
    # The restart may cut the ADB session before the reply; C003 decides.
    try {
        $proof.RequestOutput=(Run-Process 'loader-request' $adb "-s $serial shell /bin/mibox reboot-loader --boot-id $bootId" 10).Output
    } catch {
        $proof.RequestError=$_.Exception.Message
    }
    $proof.Stage='ObserveLoader'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $returned=$null
    while($clock.Elapsed.TotalSeconds -lt $ObserveSeconds) {
        $nodes=@(Get-Loader)
        if($nodes.Count -eq 1 -and $nodes[0].Status -eq 'OK'){$returned=$clock.Elapsed.TotalSeconds;break}
        Start-Sleep -Milliseconds 500
    }
    if($null -eq $returned){throw "No C003 within $ObserveSeconds s; power-cycle manually, no retry sent"}
    $proof.LoaderSeconds=$returned
    $identify=(Run-Process 'loader-identify' (Join-Path $PSHOME 'powershell.exe') (
        '-NoProfile -File "'+(Join-Path $PSScriptRoot 'Probe-MiboxUsbLoader.ps1')+'" -Identify') 20).Output | ConvertFrom-Json
    if(-not $identify.Found -or $identify.VidPid -cne '1B8E:C003' -or $identify.IdentifyHex -cne '00-08-00-10') {
        throw 'Unverified loader identity'
    }
    $proof.LoaderIdentity=$identify
    $proof.LoaderRestartVerified=$true;$proof.Stage='Passed'
    Write-Output "LOADER_RESTART_PASS (C003 after $([math]::Round($returned,1)) s): $evidence"
} catch {
    $proof.Failure=$_.Exception.Message
    throw
} finally {
    $proof.FinishedAt=[DateTime]::UtcNow.ToString('o')
    $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
}
