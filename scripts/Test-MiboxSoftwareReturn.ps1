param([Parameter(Mandatory=$true)][string]$AndroidBaseline,
    [ValidateRange(10,300)][int]$TimeoutSeconds=180,
    [ValidateSet('Restart','Health','Hardware','Hardware2','Hardware3','Capture','DisplayCapture','Console','ContainerKernel','ContainerKernel2','DockerKernel','DockerKernel2')][string]$Candidate='Restart')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$baseline=Get-Content -LiteralPath $AndroidBaseline -Raw | ConvertFrom-Json
if(-not $baseline.Fingerprint -or $baseline.BootCompleted -ne '1') {throw 'Verified Android baseline required'}
$evidence=Join-Path $repo ('artifacts/software-return/return-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence | Out-Null
$proof=[ordered]@{}
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$script:adbSequence=0
function Invoke-Adb([string]$Arguments, [switch]$AllowFailure) {
    $script:adbSequence++
    $name='adb-'+$script:adbSequence.ToString('D4')
    try {
        return [pscustomobject](Run-Process $name $adb $Arguments 8)
    } catch {
        if(-not $AllowFailure) {throw}
        # A disconnect during the single restart request is not a return verdict.
        # Preserve the failed process record; only later complete queries can pass.
        return Get-Content -Raw -LiteralPath (Join-Path $evidence ($name+'.json')) | ConvertFrom-Json
    }
}
function Test-AdbComplete($Record) {
    return $Record.ExitCode -eq 0 -and -not $Record.TimedOut -and $Record.OutputComplete -and -not $Record.Failure
}
function Save-Proof {
    $proof | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $evidence 'result.json')
}
try {
    $proof.AndroidBaseline=$baseline
    $proof.Os=Invoke-Adb '-s 248243005297 shell cat /etc/os-release'
    if($proof.Os.TimedOut -or $proof.Os.Output -notmatch '(?m)^ID=mibox-custom\s*$') {throw 'Custom OS required; no restart requested'}
    $proof.BootId=Invoke-Adb '-s 248243005297 shell cat /proc/sys/kernel/random/boot_id'
    $bootId=$proof.BootId.Output
    if($proof.BootId.TimedOut -or $bootId -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'Invalid custom boot ID'}
    $pins=[ordered]@{
        init='6ae13b3ed03864432edc4ca0f9ed8f9b46f6d6e6eeba690cf77dbbac0bc8e780'
        mibox='3e2d9a45aeff3d6b0bf727b1d1aadd31f8c776bf30fe62bf053ae3ac8ad240ce'
    }
    if($Candidate -eq 'Health') {
        $pins.init='8c2f9bcd4c5c26585062fbb5f44c7aeadbbe975217d28ab939f65173cb61cb6a'
        $pins.mibox='2e4f1dfd8f28c0bf52323a9e65abf314e1e1705505414cc7cc25fcdf99128512'
    }
    if($Candidate -in @('Hardware','Hardware2','Hardware3')) {
        $pins.init='c9685fe4a4e6892a273917e0b82f77d0cd74320245d43ec413cea8b59b213c4b'
        $pins.mibox='e8fa69daba2bb78b42fdff17ca3819fe2bcf5afb007c129aad3384e0053adecf'
    }
    if($Candidate -in @('Capture','DisplayCapture')) {
        $pins.init='ba4df3e7ab537cad89cae844b4a5821017179d4f75cbfa79b0700c81440d3b4c'
        $pins.mibox='e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07'
    }
    if($Candidate -eq 'Console') {
        $pins.init='9333195a11b758f7531547008b927849da228ceddb41398d3d2b8bca25258438'
        $pins.mibox='e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07'
    }
    if($Candidate -eq 'ContainerKernel') {
        $pins.init='390f64c8d0dc5aacb5ea7dad67bb38b3569fb11e55629f9d77c510cff5991a1f'
        $pins.mibox='e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07'
    }
    if($Candidate -in @('ContainerKernel2','DockerKernel','DockerKernel2')) {
        $pins.init='e77771fc585ebf0ea0be44c8f319179e77e728146c7b2b0916626bdfed52c2d2'
        $pins.mibox='e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07'
    }
    $proof.Candidate=$Candidate
    foreach($name in $pins.Keys) {
        $remote=if($name -eq 'init') {'/init'} else {'/bin/mibox'}
        $local=Join-Path $evidence ($name+'.elf')
        $proof['Pull'+$name]=Invoke-Adb ('-s 248243005297 pull '+$remote+' "'+$local+'"')
        if($proof['Pull'+$name].TimedOut -or $proof['Pull'+$name].ExitCode -ne 0 -or -not (Test-Path -LiteralPath $local)) {throw ('Pull failed: '+$name)}
        $hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash.ToLowerInvariant()
        $proof[$name+'Sha256']=$hash
        if($hash -ne $pins[$name]) {throw ('Physical executable hash mismatch: '+$name)}
    }
    $proof.Pid1=Invoke-Adb '-s 248243005297 shell cat /proc/1/status'
    if($proof.Pid1.Output -notmatch '(?m)^Name:\s+init\s*$' -or $proof.Pid1.Output -notmatch '(?m)^Pid:\s+1\s*$') {throw 'PID1 identity missing'}
    $proof.Check=Invoke-Adb '-s 248243005297 shell /bin/mibox reboot-android --check'
    if($proof.Check.TimedOut -or $proof.Check.Output -ne ('MIBOX_RESTART_READY boot_id='+$bootId)) {throw 'Restart readiness failed; no restart requested'}
    Save-Proof
    Write-Output ('Verified custom PID1/toolbox and restart readiness: '+$bootId)
    # Send once only. Exit status/acknowledgment is not the return verdict.
    $proof.Request=Invoke-Adb ('-s 248243005297 shell /bin/mibox reboot-android --boot-id '+$bootId) -AllowFailure
    Save-Proof
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $returned=$false
    while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $devices=Invoke-Adb 'devices -l' -AllowFailure
        $event=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Adb=$devices}
        if((Test-AdbComplete $devices) -and $devices.Output -match '(?m)^248243005297\s+device\b') {
            $android=Invoke-Adb '-s 248243005297 shell getprop ro.build.fingerprint; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id' -AllowFailure
            $event.Android=$android
            $lines=@(($android.Output -replace "`r",'') -split "`n" | Where-Object {$_ -ne ''})
            if((Test-AdbComplete $android) -and $lines.Count -eq 3 -and
                $lines[0] -eq $baseline.Fingerprint -and $lines[1] -eq '1' -and
                $lines[2] -match '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -and
                $lines[2] -ne $bootId -and $lines[2] -ne $baseline.BootId) {
                $proof.AndroidReturn=$android; $returned=$true
            }
        }
        $event | ConvertTo-Json -Depth 6 -Compress | Add-Content -Encoding UTF8 (Join-Path $evidence 'events.jsonl')
        if($returned) {break}
        Start-Sleep -Seconds 2
    }
    $proof.PhysicalAndroidReturnVerified=$returned
    if(-not $returned) {throw 'Android return not verified within timeout; no restart retry sent'}
    Write-Output 'PASS: new Android boot ID, original fingerprint and boot_completed=1'
} catch {
    $proof.Failure=$_.Exception.Message
    throw
} finally {
    Save-Proof
    Write-Output ('Evidence: '+$evidence)
}
