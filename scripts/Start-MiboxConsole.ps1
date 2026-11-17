param([switch]$Boot, [switch]$Connect, [switch]$Stop,
    [string]$IdentityFile=(Join-Path $env:USERPROFILE '.ssh/mibox-console'))
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {throw 'Owner SSH private key is missing'}
# Flash-installed Slim (2026-11-17): persistence and SSH start by themselves and
# the host key is the fixed Alpine key. With only -Connect and the target absent
# from USB ADB (cable unplugged for flash boots), connect directly over the LAN.
if($Connect -and -not $Boot -and -not $Stop) {
    $adbPath=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
    $listed=if(Test-Path -LiteralPath $adbPath) {(& $adbPath devices) -join "`n"} else {''}
    if($listed -notmatch '(?m)^248243005297\s') {
        $persistentKnown=Join-Path $repo 'assets/ssh/mibox-persistent-known-hosts'
        & ssh.exe -i $IdentityFile -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$persistentKnown" root@192.168.1.222
        exit $LASTEXITCODE
    }
}
$linuxRepoOutput=& wsl.exe -e wslpath -u ($repo.Replace('\','/'))
if($LASTEXITCODE -ne 0 -or -not $linuxRepoOutput) {throw 'Could not resolve WSL workspace path'}
$linuxRepo=$linuxRepoOutput.Trim()
$linuxKeyOutput=& wsl.exe -e wslpath -u ($IdentityFile.Replace('\','/'))
if($LASTEXITCODE -ne 0 -or -not $linuxKeyOutput) {throw 'Could not resolve WSL identity path'}
$linuxKey=$linuxKeyOutput.Trim()
$launchArgs=@('-e','python3',($linuxRepo+'/scripts/start-console.py'),'--private-key',$linuxKey)
if($Boot) {$launchArgs+='--boot-if-needed'}
if($Stop) {$launchArgs+='--stop'}
& wsl.exe @launchArgs
if($LASTEXITCODE -ne 0) {throw 'Console launcher failed; see artifacts/console-ssh/launcher-*'}
if($Connect -and -not $Stop) {
    $known=(Get-Content -Raw -LiteralPath (Join-Path $repo 'target/console-known-hosts-path.txt')).Trim()
    & ssh.exe -i $IdentityFile -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known" root@192.168.1.222
}
