# Explicit tests in the separately pinned Hardware RAM candidate; never Android.
param([Parameter(Mandatory=$true)][ValidateSet('Network','Display','Audio')][string]$Action,
    [ValidateSet('Hardware','Hardware2','Hardware3')][string]$Candidate='Hardware')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/network-hdmi-audio/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$Action.ToLowerInvariant())
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$proof=[ordered]@{Action=$Action;StartedAt=(Get-Date).ToString('o');DeviceAccessed=$false;HelperSucceeded=$false;FunctionalPass=$false;OwnerConfirmationRequired=($Action -ne 'Network')}
$proof.ScriptSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$proof.Candidate=$Candidate
function Read-Adb([string]$Name,[string]$Arguments,[int]$Seconds=10) {Run-Process $Name $adb $Arguments $Seconds}
try {
    $proof.DeviceAccessed=$true
    $os=(Read-Adb 'os' '-s 248243005297 shell cat /etc/os-release').Output
    if($os -notmatch '(?m)^ID=mibox-custom\s*$'){throw 'Custom RAM system required'}
    $bootId=(Read-Adb 'boot-before' '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id').Output
    if($bootId -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'){throw 'Invalid boot ID'}
    $proof.BootId=$bootId
    $pins=[ordered]@{
        init=@('/init','c9685fe4a4e6892a273917e0b82f77d0cd74320245d43ec413cea8b59b213c4b')
        mibox=@('/bin/mibox','e8fa69daba2bb78b42fdff17ca3819fe2bcf5afb007c129aad3384e0053adecf')
        helper=@('/sbin/mibox-hardware','1e47e6ea7ae9200e1613200f7c9ccb60c554979ee0d139635f8d3c66ce862f71')
    }
    if($Candidate -eq 'Hardware2') {$pins.helper[1]='73958f116d5fd38887e79ec66dca9f4387c7f9e12d7fa67e5baf860b8a5c6725'}
    if($Candidate -eq 'Hardware3') {$pins.helper[1]='1d21c17cfec18992a104e163180fea5b632ec06290b452e19a9b200504c379d3'}
    foreach($name in $pins.Keys) {
        $local=Join-Path $evidence ($name+'.elf')
        [void](Read-Adb ('pull-'+$name) ('-s 248243005297 pull '+$pins[$name][0]+' "'+$local+'"'))
        $hash=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne $pins[$name][1]){throw ('Hardware candidate hash mismatch: '+$name)}
        $proof[$name+'Sha256']=$hash
    }
    $ready=(Read-Adb 'restart-ready' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if($ready -cne ('MIBOX_RESTART_READY boot_id='+$bootId)){throw 'Restart channel not ready'}
    if($Candidate -eq 'Hardware3') {
        $networkProfile=(Read-Adb 'static-profile' '-s 248243005297 shell /bin/mibox cat /etc/mibox-network-static').Output
        if($networkProfile -cne 'MIBOX_STATIC_IPV4_V1 192.168.1.222 255.255.255.0 192.168.1.1'){throw 'Owner-confirmed static profile mismatch'}
        $proof.StaticProfile=$networkProfile
    }
    $command='-s 248243005297 shell "/bin/mibox hardware-test '+$Action.ToLowerInvariant()+' --boot-id '+$bootId+'; result=$?; echo MIBOX_COMMAND_EXIT=$result"'
    $result=(Read-Adb 'hardware-test' $command 65).Output.Replace("`r",'')
    $proof.Output=$result
    if(-not $result.EndsWith("MIBOX_HARDWARE_EXIT=0`nMIBOX_COMMAND_EXIT=0")){throw 'Hardware helper or toolbox failed; inspect evidence before retry'}
    $proof.HelperSucceeded=$true
    $after=(Read-Adb 'boot-after' '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id').Output
    if($after -cne $bootId){throw 'Boot identity changed during test'}
    $ready=(Read-Adb 'restart-ready-after' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if($ready -cne ('MIBOX_RESTART_READY boot_id='+$bootId)){throw 'Restart channel unavailable after test'}
    if($Action -eq 'Network') {
        $net=(Read-Adb 'network-after' '-s 248243005297 shell /bin/mibox net').Output
        $fib=(Read-Adb 'ipv4-fib-after' '-s 248243005297 shell "/bin/mibox cat /proc/net/fib_trie; result=$?; echo MIBOX_FIB_EXIT=$result"').Output.Replace("`r",'')
        $lease=[regex]::Match($result,'(?<mode>dhcp|static)_address=(?<address>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ')
        if($result -notmatch 'gateway_echo_replies=3/3' -or $result -notmatch 'network_cleanup=ok' -or
           $net -notmatch '(?m)^eth0\s+down\s' -or $net -match '(?m)^eth0\s+[0-9A-Fa-f]{8}\s' -or
           -not $fib.EndsWith('MIBOX_FIB_EXIT=0') -or
           -not $lease.Success -or $fib -match ('\b'+[regex]::Escape($lease.Groups['address'].Value)+'\b')) {throw 'Network traffic or cleanup not verified'}
        if($Candidate -eq 'Hardware3' -and ($lease.Groups['mode'].Value -cne 'static' -or $lease.Groups['address'].Value -cne '192.168.1.222')){throw 'Static profile was not used'}
        $proof.AddressConfiguration=$lease.Groups['mode'].Value
        $proof.IPv4Address=$lease.Groups['address'].Value
        $proof.FunctionalPass=$true
        $proof.Scope='Explicit RAM-only IPv4 configuration, address conflict probes, three gateway echo replies, then IPv4/route removal and eth0 down; no DNS/Internet/long-duration claim'
    } elseif($Action -eq 'Display') {
        if($result -notmatch 'framebuffer_restore=ok' -or $result -notmatch 'MIBOX_HDMI_PATTERN_WRITTEN'){throw 'Framebuffer write/restore missing'}
        $proof.Scope='Framebuffer writes and restoration only; visible HDMI output requires owner observation'
    } else {
        if($result -notmatch 'pcm_frames_accepted=144000' -or $result -notmatch 'MIBOX_AUDIO_FRAMES_WRITTEN'){throw 'PCM transfer incomplete'}
        $proof.Scope='PCM frames accepted by device 0; audible HDMI output requires owner observation'
    }
    Write-Output ('Hardware helper completed: '+$Action)
} catch {$proof.Failure=$_.Exception.Message;throw}
finally {
    $proof.FinishedAt=(Get-Date).ToString('o')
    $proof | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
    Write-Output ('Evidence: '+$evidence)
}
