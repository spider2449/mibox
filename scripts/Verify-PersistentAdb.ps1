param([switch]$Reboot, [int]$TimeoutSeconds = 180)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$adbPath=Join-Path $repoRoot 'phone-tools/platform-tools/adb.exe'
$evidence=Join-Path $repoRoot ('artifacts/adb-persistence/verification-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
function Invoke-Adb([string]$Arguments,[int]$Timeout=4000) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$adbPath
    $start.Arguments="-s 248243005297 $Arguments"
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    [void]$process.Start()
    $outTask=$process.StandardOutput.ReadToEndAsync()
    $errTask=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit($Timeout)) {
        $process.Kill(); $process.WaitForExit(); $process.Dispose()
        return [pscustomobject]@{Code=-1; Output=''; Error='timeout'}
    }
    $process.WaitForExit()
    $result=[pscustomobject]@{Code=$process.ExitCode; Output=$outTask.Result; Error=$errTask.Result}
    $process.Dispose()
    return $result
}
$before=Invoke-Adb 'shell cat /proc/sys/kernel/random/boot_id'
$beforeId=$before.Output.Trim()
if($beforeId -notmatch '^[0-9a-f-]{36}$') {throw 'Cannot read boot ID; no reboot requested'}
$beforeId | Set-Content (Join-Path $evidence 'boot-id-before.txt') -Encoding UTF8
if($Reboot) {
    $restart=Invoke-Adb 'reboot'
    "$($restart.Code) $($restart.Output) $($restart.Error)" | Set-Content (Join-Path $evidence 'reboot-request.txt') -Encoding UTF8
    if($restart.Code -ne 0) {throw 'ADB reboot request failed'}
}
$clock=[Diagnostics.Stopwatch]::StartNew()
$stableSince=$null
$lastPhase=''
$passed=$false
$afterId=$null
$lastSnapshot=''
while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $boot=Invoke-Adb 'shell getprop sys.boot_completed' 2500
    $phase='waiting for USB and boot completion'
    if($boot.Output.Trim() -eq '1') {
        $query='shell echo BOOT_ID; cat /proc/sys/kernel/random/boot_id; echo ADB_ENABLED; settings get global adb_enabled; echo USB_PERSIST; getprop persist.sys.usb.config; echo USB_STATE; getprop sys.usb.state; echo ENFORCEMENT; getenforce; echo BLOCK_RO; cat /sys/class/block/system1/ro; echo SYSTEM_MOUNT; cat /proc/mounts; echo HOOK_LOG; cat /data/local/tmp/mibox-adb-boot.log'
        $snapshot=Invoke-Adb $query 6000
        $text=$snapshot.Output.Replace("`r",'')
        $lines=@($text.Split("`n") | Where-Object {$_ -ne ''})
        function Value-After([string]$Marker) {
            $position=[array]::IndexOf($lines,$Marker)
            if($position -ge 0 -and $position+1 -lt $lines.Count) {return $lines[$position+1]}
            return ''
        }
        $afterId=Value-After 'BOOT_ID'
        $lastBlock=($text -split 'MIBOX_ADB_HOOK_BEGIN')[-1]
        $mountLine=$lines | Where-Object {$_ -match '^/dev/block/system1 /system ext4 '}
        $mountRo=$mountLine -and (($mountLine -split '\s+')[3] -match '(^|,)ro(,|$)')
        $newBoot=(-not $Reboot) -or ($afterId -match '^[0-9a-f-]{36}$' -and $afterId -ne $beforeId)
        $valid=$newBoot -and (Value-After 'ADB_ENABLED') -eq '1' -and
            (Value-After 'USB_PERSIST') -eq 'adb' -and (Value-After 'USB_STATE') -eq 'adb' -and
            (Value-After 'ENFORCEMENT') -eq 'Enforcing' -and (Value-After 'BLOCK_RO') -eq '1' -and
            $mountRo -and $lastBlock.Contains($afterId) -and $lastBlock.Contains('MIBOX_ADB_HOOK_DONE')
        $lastSnapshot=$text
        if($valid) {
            if($null -eq $stableSince) {$stableSince=$clock.Elapsed.TotalSeconds}
            $phase='hook complete; verifying 20 seconds of stable USB ADB'
            if($clock.Elapsed.TotalSeconds-$stableSince -ge 20) {$passed=$true; break}
        } else {
            $stableSince=$null
            $phase='USB online; waiting for this boot hook and saved allow state'
        }
    } else {$stableSince=$null}
    if($phase -ne $lastPhase) {Write-Output "$([int]$clock.Elapsed.TotalSeconds)s $phase"; $lastPhase=$phase}
    Start-Sleep -Seconds 2
}
$lastSnapshot | Set-Content (Join-Path $evidence 'final-snapshot.txt') -Encoding UTF8
[ordered]@{Passed=$passed; RebootRequested=[bool]$Reboot; BeforeBootId=$beforeId; AfterBootId=$afterId; ElapsedSeconds=$clock.Elapsed.TotalSeconds; Evidence=$evidence} | ConvertTo-Json | Set-Content (Join-Path $evidence 'result.json') -Encoding UTF8
Write-Output "Evidence: $evidence"
if(-not $passed) {throw 'Persistent ADB verification did not pass'}
if($Reboot) {Write-Output 'PERSISTENT_USB_ADB_REBOOT_VERIFIED'}
else {Write-Output 'PERSISTENT_USB_ADB_CURRENT_BOOT_VERIFIED'}
