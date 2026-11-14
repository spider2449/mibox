# Explicit capture from a separately built RAM rootfs, with executable readback.
param([Parameter(Mandatory=$true)][string]$ManifestPath, [switch]$DisplayPattern)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$evidence=Join-Path $repo ('artifacts/framebuffer-capture/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence | Out-Null
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$proof=[ordered]@{DeviceAccessed=$false;CaptureVerified=$false;HdmiScanoutVerified=$false;Scope='Framebuffer memory only; no physical HDMI claim'}
function Read-Adb([string]$Name,[string]$Arguments,[int]$Seconds=10) {Run-Process $Name $adb $Arguments $Seconds}
function Wsl-Path([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if($full -notmatch '^([A-Za-z]):\\'){throw 'WSL conversion requires a local drive path'}
    return '/mnt/'+$Matches[1].ToLowerInvariant()+'/'+$full.Substring(3).Replace('\','/')
}
try {
    $manifest=Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $proof.ManifestSHA256=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $evidence 'rootfs-manifest.json')
    $pins=[ordered]@{init='init';mibox='bin/mibox';helper='sbin/mibox-hardware'}
    foreach($key in $pins.Keys) {
        if($manifest.files.($pins[$key]).sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid executable manifest'}
    }
    $pythonCommand=Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $useWsl=$null -eq $pythonCommand
    if($useWsl){$python=(Get-Command wsl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source}
    else {$python=$pythonCommand.Source}
    $proof.DeviceAccessed=$true
    $os=(Read-Adb 'os' '-s 248243005297 shell cat /etc/os-release').Output
    if($os -notmatch '(?m)^ID=mibox-custom\s*$'){throw 'Custom RAM system required'}
    $boot=(Read-Adb 'boot-before' '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id').Output
    if($boot -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'){throw 'Invalid boot identity'}
    $proof.BootId=$boot
    foreach($key in $pins.Keys) {
        $local=Join-Path $evidence ($key+'.elf')
        [void](Read-Adb ('pull-'+$key) ('-s 248243005297 pull /'+$pins[$key]+' "'+$local+'"'))
        $hash=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne $manifest.files.($pins[$key]).sha256){throw ('Executable pin mismatch: '+$key)}
        $proof[$key+'SHA256']=$hash
    }
    $ready=(Read-Adb 'ready-before' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if($ready -cne ('MIBOX_RESTART_READY boot_id='+$boot)){throw 'Restart readiness missing'}
    $action=if($DisplayPattern){'display'}else{'capture'}
    $command='-s 248243005297 shell "/bin/mibox hardware-test '+$action+' --boot-id '+$boot+'; result=$?; echo MIBOX_COMMAND_EXIT=$result"'
    $output=(Read-Adb 'capture' $command 65).Output.Replace("`r",'')
    if(-not $output.EndsWith("MIBOX_HARDWARE_EXIT=0`nMIBOX_COMMAND_EXIT=0") -or
       $output -notmatch '(?m)^MIBOX_FRAMEBUFFER_CAPTURE path=/dev/mibox-framebuffer.ppm width=[0-9]+ height=[0-9]+ format=P6 scope=framebuffer_only$') {throw 'Fresh capture not established'}
    if($DisplayPattern -and ($output -notmatch '(?m)^framebuffer_restore=ok$' -or
        $output -notmatch '(?m)^MIBOX_HDMI_PATTERN_WRITTEN owner_visual_confirmation=required$')) {throw 'Display restoration not established'}
    $ppm=Join-Path $evidence 'framebuffer.ppm'
    $png=Join-Path $evidence 'framebuffer.png'
    [void](Read-Adb 'pull-capture' ('-s 248243005297 pull /dev/mibox-framebuffer.ppm "'+$ppm+'"'))
    $converter=Join-Path $PSScriptRoot 'framebuffer_ppm.py'
    $conversion='"'+$converter+'" "'+$ppm+'" "'+$png+'"'
    if($useWsl){$conversion='--exec python3 "'+(Wsl-Path $converter)+'" "'+(Wsl-Path $ppm)+'" "'+(Wsl-Path $png)+'"'}
    if($DisplayPattern){$conversion+=' --expect-color-bars'}
    [void](Run-Process 'convert' $python $conversion 30)
    $after=(Read-Adb 'boot-after' '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id').Output
    $ready=(Read-Adb 'ready-after' '-s 248243005297 shell /bin/mibox reboot-android --check').Output
    if($after -cne $boot -or $ready -cne ('MIBOX_RESTART_READY boot_id='+$boot)){throw 'Boot identity or restart readiness changed'}
    $proof.PpmSHA256=(Get-FileHash -LiteralPath $ppm -Algorithm SHA256).Hash.ToLowerInvariant()
    $proof.PngSHA256=(Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash.ToLowerInvariant()
    $proof.CaptureVerified=$true
    $proof.ColorBarsVerified=[bool]$DisplayPattern
    Write-Output ('Framebuffer capture: '+$png)
} catch {$proof.Failure=$_.Exception.Message;throw}
finally {
    $proof.FinishedAt=[DateTime]::UtcNow.ToString('o')
    $proof | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'result.json')
    Write-Output ('Evidence: '+$evidence)
}
