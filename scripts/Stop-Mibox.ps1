# Stop persistence on the running MiBOX custom system before power-off, or
# restart it (-Restart). Data is unmounted cleanly first in both cases.
#
#   powershell -NoProfile -File scripts/Stop-Mibox.ps1            # stop, then safe to cut power
#   powershell -NoProfile -File scripts/Stop-Mibox.ps1 -Restart   # stop and restart (USB unplugged)
#
# USB ADB attached: runs over ADB (outside Alpine) and shows the exact result.
# Otherwise: runs over SSH from a RAM-rooted shell (the stop ends the SSH
# session itself), then confirms SSH is gone (and, with -Restart, back with a
# new boot ID). Host key: assets/ssh/mibox-persistent-known-hosts (strict).
param([switch]$Restart,
    [string]$IdentityFile=(Join-Path $env:USERPROFILE '.ssh/mibox-console'),
    [ValidateRange(30,600)][int]$RestartWaitSeconds=180)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$serial='248243005297'
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$known=Join-Path $repo 'assets/ssh/mibox-persistent-known-hosts'
$sshBase=@('-i',$IdentityFile,'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
    '-o',"UserKnownHostsFile=$known",'-o','ConnectTimeout=5','root@192.168.1.222')
function Ssh-Run([string]$Command) {
    # PowerShell 5.1 turns captured native stderr (e.g. "Connection closed by
    # remote host", expected here) into terminating errors under 'Stop'.
    $saved=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try {
        $output=& ssh.exe @sshBase $Command 2>&1
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$saved }
    return @{Code=$code; Text=(($output | ForEach-Object { "$_" }) -join "`n").Trim()}
}
function Wait-SshDown([int]$Seconds) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt $Seconds) {
        if((Ssh-Run 'true').Code -ne 0) {return $true}
        Start-Sleep -Seconds 1
    }
    return $false
}

$usb=$false
if(Test-Path -LiteralPath $adb) {
    $usb=((& $adb devices) -join "`n") -match "(?m)^$serial\s+(device|recovery)"
}

if($usb) {
    if($Restart) {
        throw 'USB cable is attached: a restart would stop at the C003 loader and wait there. Unplug the cable and run again (SSH path), or stop here and power-cycle without the cable.'
    }
    $bootId=((& $adb -s $serial shell cat /proc/sys/kernel/random/boot_id) -join '').Trim()
    if($bootId -notmatch '^[0-9a-f-]{36}$') {throw "Unexpected boot ID over USB: $bootId"}
    Write-Host "USB ADB: boot $bootId"
    $result=(& $adb -s $serial shell "/bin/mibox persist-stop --boot-id $bootId; echo MOUNTED=`$(grep -c ' 179:11 ' /proc/self/mountinfo)") -join "`n"
    Write-Host $result
    if($result -notmatch 'MIBOX_PERSIST_STOP_EXIT=0' -or $result -notmatch 'MOUNTED=0') {
        throw 'Persistence stop FAILED or data still mounted: do NOT cut power. See the output above.'
    }
    Write-Host 'MIBOX_STOPPED: data unmounted, only RAM filesystems remain. Safe to cut power.'
    exit 0
}

if(-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {throw 'Owner SSH private key is missing'}
$id=Ssh-Run 'cat /proc/sys/kernel/random/boot_id'
if($id.Code -ne 0 -or $id.Text -notmatch '^[0-9a-f-]{36}$') {
    throw "Cannot reach the box over SSH (persistence may already be stopped): $($id.Text)"
}
$bootId=$id.Text
Write-Host "SSH: boot $bootId"
$inner="mibox persist-stop --boot-id $bootId > /tmp/stop.out 2>&1"
if($Restart) {$inner+=" && mibox reboot-android --boot-id $bootId >> /tmp/stop.out 2>&1"}
# exec: the request runs with a RAM root, so stopping Alpine (incl. this SSH
# session) cannot kill it. The session closing is the expected outcome.
# Single quotes only: Windows PowerShell 5.1 strips embedded double quotes
# from native-command arguments, which broke the remote command.
$null=Ssh-Run "exec chroot /proc/1/root /bin/sh -c '$inner'"
if(-not (Wait-SshDown 30)) {
    throw 'SSH is still answering 30 s after the stop request: the stop did not take effect. Do NOT cut power; check over USB (/tmp/stop.out).'
}
if(-not $Restart) {
    Start-Sleep -Seconds 5
    Write-Host 'MIBOX_STOP_REQUESTED: SSH has shut down, which happens as part of the stop.'
    Write-Host 'Safe to cut power now. For the exact result, plug in USB and run:'
    Write-Host "  phone-tools\platform-tools\adb.exe -s $serial shell cat /tmp/stop.out"
    exit 0
}
Write-Host "Restarting; waiting up to $RestartWaitSeconds s for SSH..."
$clock=[Diagnostics.Stopwatch]::StartNew()
while($clock.Elapsed.TotalSeconds -lt $RestartWaitSeconds) {
    Start-Sleep -Seconds 2
    $new=Ssh-Run 'cat /proc/sys/kernel/random/boot_id'
    if($new.Code -eq 0 -and $new.Text -match '^[0-9a-f-]{36}$' -and $new.Text -ne $bootId) {
        Write-Host ("MIBOX_RESTARTED: new boot {0} after {1:N0} s" -f $new.Text,$clock.Elapsed.TotalSeconds)
        exit 0
    }
}
throw "No SSH with a new boot ID within $RestartWaitSeconds s. If the USB cable is plugged into the PC the box waits at C003; otherwise check HDMI/power."
