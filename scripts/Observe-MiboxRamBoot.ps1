param([ValidateRange(1,180)][int]$TimeoutSeconds=120)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$evidence=Join-Path $repo ('artifacts/usb-loader-protocol/ram-boot-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$script:adbQueryNumber=0
function Invoke-FixedAdb([string]$Arguments) {
    $script:adbQueryNumber++
    $name='adb-{0:d3}' -f $script:adbQueryNumber
    try {
        return [pscustomobject](Run-Process $name $adb $Arguments 5)
    } catch {
        # Expected while USB reconnects or a stock-only command is unavailable.
        # Preserve the failure, and let the observer's identity gates reject it.
        $record=Join-Path $evidence ($name+'.json')
        if(-not (Test-Path -LiteralPath $record)){throw}
        return Get-Content -Raw -LiteralPath $record | ConvertFrom-Json
    }
}
$clock=[Diagnostics.Stopwatch]::StartNew()
$last=''; $connected=$false
while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $devices=Invoke-FixedAdb 'devices -l'
    $usb=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {$_.InstanceId -match '^USB\\VID_(1B8E|18D1)'} |
        Select-Object Status,FriendlyName,InstanceId)
    $state=@{Adb=$devices;Usb=$usb}
    $encoded=$state | ConvertTo-Json -Depth 6 -Compress
    if($encoded -ne $last) {
        @{Utc=[DateTime]::UtcNow.ToString('o');Elapsed=$clock.Elapsed.TotalSeconds;State=$state} |
            ConvertTo-Json -Depth 8 -Compress | Add-Content -Encoding UTF8 (Join-Path $evidence 'events.jsonl')
        $last=$encoded
    }
    # Stock recovery adbd advertises recovery even under the custom initramfs.
    if($devices.ExitCode -eq 0 -and -not $devices.TimedOut -and $devices.OutputComplete -and
       $devices.Output -match '(?m)^248243005297\s+(device|recovery)\b') {$connected=$true;break}
    Start-Sleep -Seconds 2
}
$proof=@{}
if($connected) {
    $queries=[ordered]@{
        osRelease='shell cat /etc/os-release'
        pid1='shell cat /proc/1/comm'
        bootId='shell cat /proc/sys/kernel/random/boot_id'
        cmdline='shell cat /proc/cmdline'
        kernel='shell uname -a'
        identity='shell id'
        customTool='shell /bin/mibox info'
        androidBootCompleted='shell getprop sys.boot_completed'
    }
    foreach($entry in $queries.GetEnumerator()) {
        $proof[$entry.Key]=Invoke-FixedAdb ('-s 248243005297 '+$entry.Value)
    }
}
$identityComplete=$connected
foreach($key in @('osRelease','pid1','bootId')) {
    if(-not $connected -or $proof[$key].TimedOut -or
       -not $proof[$key].OutputComplete -or $proof[$key].ExitCode -ne 0) {
        $identityComplete=$false
    }
}
$custom=$identityComplete -and $proof.osRelease.ExitCode -eq 0 -and
    $proof.osRelease.Output -match '(?m)^ID=mibox-custom\s*$' -and
    $proof.pid1.ExitCode -eq 0 -and $proof.bootId.ExitCode -eq 0
$result=[ordered]@{AdbConnected=$connected;CustomOsMarkerObserved=[bool]$custom;Proof=$proof;Evidence=$evidence}
$result | ConvertTo-Json -Depth 6 | Tee-Object -FilePath (Join-Path $evidence 'result.json')
# A marker proves the supplied userspace is answering; it does not establish
# complete hardware support or persistent installation.
