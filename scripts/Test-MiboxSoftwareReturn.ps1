param([Parameter(Mandatory=$true)][string]$AndroidBaseline,
    [ValidateRange(10,300)][int]$TimeoutSeconds=180,
    [ValidateSet('Restart','Health')][string]$Candidate='Restart')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$baseline=Get-Content -LiteralPath $AndroidBaseline -Raw | ConvertFrom-Json
if(-not $baseline.Fingerprint -or $baseline.BootCompleted -ne '1') {throw 'Verified Android baseline required'}
$evidence=Join-Path $repo ('artifacts/software-return/return-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidence | Out-Null
$proof=[ordered]@{}
function Invoke-Adb([string]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$adb; $start.Arguments=$Arguments
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $timedOut=-not $process.WaitForExit(8000)
        if($timedOut) {$process.Kill()}
        $process.WaitForExit()
        return [pscustomobject]@{Utc=[DateTime]::UtcNow.ToString('o');Arguments=$Arguments;ExitCode=$process.ExitCode;TimedOut=$timedOut;Output=$stdout.Result.Trim();Error=$stderr.Result.Trim()}
    } finally {$process.Dispose()}
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
    $proof.Request=Invoke-Adb ('-s 248243005297 shell /bin/mibox reboot-android --boot-id '+$bootId)
    Save-Proof
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $returned=$false
    while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $devices=Invoke-Adb 'devices -l'
        $event=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Adb=$devices}
        if($devices.Output -match '(?m)^248243005297\s+device\b') {
            $android=Invoke-Adb '-s 248243005297 shell getprop ro.build.fingerprint; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id'
            $event.Android=$android
            $lines=@(($android.Output -replace "`r",'') -split "`n" | Where-Object {$_ -ne ''})
            if(-not $android.TimedOut -and $android.ExitCode -eq 0 -and $lines.Count -eq 3 -and
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
