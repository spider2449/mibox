param([int]$TimeoutSeconds=120,
      [ValidateSet('usb_burning','usb_burner_reboot')][string]$RebootTarget='usb_burning')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$evidence=Join-Path $repo ('artifacts/usb-loader-mode/'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
function Invoke-Adb([string]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$adb; $start.Arguments="-s 248243005297 $Arguments"
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    [void]$process.Start()
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(5000)) {$process.Kill(); $process.WaitForExit(); $process.Dispose(); throw 'ADB request timed out'}
    $process.WaitForExit()
    $result=[pscustomobject]@{Code=$process.ExitCode;Output=$outTask.Result.Trim();Error=$errTask.Result.Trim()}
    $process.Dispose(); return $result
}
function Get-UsbSnapshot {
    @(Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match '^USB\\'} |
        Select-Object Status,Class,FriendlyName,InstanceId)
}
$boot=Invoke-Adb 'shell getprop sys.boot_completed'
$before=Invoke-Adb 'shell cat /proc/sys/kernel/random/boot_id'
if($boot.Output -ne '1' -or $before.Output -notmatch '^[0-9a-f-]{36}$') {throw 'Stable Android boot required; no reboot requested'}
$baseline=Get-UsbSnapshot
$baseline | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidence 'usb-before.json') -Encoding UTF8
$before.Output | Set-Content (Join-Path $evidence 'boot-id-before.txt') -Encoding UTF8
$request=Invoke-Adb ("reboot "+$RebootTarget)
$request | ConvertTo-Json | Set-Content (Join-Path $evidence 'reboot-request.json') -Encoding UTF8
if($request.Code -ne 0) {throw 'Mode reboot request failed; do not retry automatically'}
$clock=[Diagnostics.Stopwatch]::StartNew()
$last=''
$found=@()
while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $snapshot=Get-UsbSnapshot
    $encoded=$snapshot | ConvertTo-Json -Depth 4 -Compress
    if($encoded -ne $last) {
        [ordered]@{Elapsed=$clock.Elapsed.TotalSeconds;Devices=$snapshot} | ConvertTo-Json -Depth 6 -Compress |
            Add-Content (Join-Path $evidence 'usb-events.jsonl') -Encoding UTF8
        $last=$encoded
    }
    $found=@($snapshot | Where-Object {$_.InstanceId -match '^USB\\VID_1B8[EA]&'})
    if($found.Count -gt 0) {break}
    Start-Sleep -Milliseconds 750
}
$properties=@()
foreach($device in $found) {
    $properties += [ordered]@{Device=$device;Properties=@(Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName @(
        'DEVPKEY_Device_ProblemCode','DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_Service') -ErrorAction SilentlyContinue |
        Select-Object KeyName,Data)}
}
[ordered]@{ModeRequest=$RebootTarget;BeforeBootId=$before.Output;LoaderUsbObserved=$found.Count -gt 0;
    ElapsedSeconds=$clock.Elapsed.TotalSeconds;Devices=$properties;ImagesUploaded=$false;FlashCommandsSent=$false;
    DriverInstalled=$false;Evidence=$evidence} | ConvertTo-Json -Depth 8 |
    Set-Content (Join-Path $evidence 'result.json') -Encoding UTF8
$found | Format-Table -AutoSize
Write-Output "Evidence: $evidence"
if($found.Count -gt 0) {Write-Output 'USB_LOADER_ENUMERATED_NO_TRANSFER'}
else {Write-Output 'USB_LOADER_NOT_OBSERVED_WITHIN_TIMEOUT'}
