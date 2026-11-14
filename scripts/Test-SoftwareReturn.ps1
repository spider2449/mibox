# Isolated return orchestration fixtures. No real ADB or USB calls.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$root=Join-Path $repo ('target/software-return-tests/'+[guid]::NewGuid().ToString())
$scripts=Join-Path $root 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Test-MiboxSoftwareReturn.ps1') $scripts
foreach($name in @('init','mibox')) {
    Copy-Item (Join-Path $repo ('artifacts/framebuffer-capture/20261115-063756-206/'+$name+'.elf')) $root
}
@'
function Run-Process($Name,$Executable,$Arguments,$DeadlineSeconds) {
    $mode=(Get-Content -Raw (Join-Path $repo 'mode.txt')).Trim()
    $boot='c076cc9c-28ed-4f2e-8f19-b014a07140bd'
    $output=''
    $record=[ordered]@{ExitCode=0;TimedOut=$false;OutputComplete=$true;Output='';Error=''}
    $calls=Join-Path $repo 'calls.txt'
    Add-Content $calls $Arguments
    if($Arguments -match '/etc/os-release') {
        $output='ID=mibox-custom'
        if($mode -eq 'identity-nonzero') {$record.ExitCode=7}
        if($mode -eq 'identity-incomplete') {$record.OutputComplete=$false}
        if($mode -eq 'identity-timeout') {$record.TimedOut=$true}
    } elseif($Arguments -match 'shell cat /proc/sys') {$output=$boot}
    elseif($Arguments -match ' pull ') {
        $name=if($Arguments -match 'pull /init ') {'init'} else {'mibox'}
        Copy-Item (Join-Path $repo ($name+'.elf')) (Join-Path $evidence ($name+'.elf'))
    } elseif($Arguments -match '/proc/1/status') {$output="Name:`tinit`nPid:`t1"}
    elseif($Arguments -match 'reboot-android --check') {$output='MIBOX_RESTART_READY boot_id='+$boot}
    elseif($Arguments -match 'reboot-android --boot-id') {
        if($mode -eq 'request-disconnect') {$record.ExitCode=1}
    } elseif($Arguments -eq 'devices -l') {$output='248243005297 device'}
    elseif($Arguments -match 'getprop') {
        $output="fixture-stock`n1`n5dc5dda3-0805-4138-9218-75822a581c85"
        $prior=@(Get-Content $calls | Where-Object {$_ -match 'getprop'}).Count
        if($prior -eq 1) {
            if($mode -eq 'return-incomplete') {$record.OutputComplete=$false}
            if($mode -eq 'return-timeout') {$record.TimedOut=$true}
            if($mode -eq 'return-nonzero') {$record.ExitCode=7}
            if($mode -eq 'return-old-boot') {$output="fixture-stock`n1`n$boot"}
            if($mode -eq 'return-not-completed') {$output="fixture-stock`n`n5dc5dda3-0805-4138-9218-75822a581c85"}
        }
    } else {throw "Unexpected fixture call: $Arguments"}
    $record.Output=$output
    $failed=$record.ExitCode -ne 0 -or $record.TimedOut -or -not $record.OutputComplete
    if($failed) {$record.Failure='Fixture process failure'}
    $record | ConvertTo-Json | Set-Content (Join-Path $evidence ($Name+'.json'))
    if($failed) {throw 'Fixture process failure'}
    return [pscustomobject]$record
}
'@ | Set-Content -Encoding UTF8 (Join-Path $scripts 'RamBootProcess.ps1')
$baseline=Join-Path $root 'baseline.json'
@{Fingerprint='fixture-stock';BootCompleted='1';BootId='6afdf09a-f36b-4499-9852-e069524d35d1'} |
    ConvertTo-Json | Set-Content $baseline
$results=@()
foreach($case in @('valid','identity-nonzero','identity-incomplete','identity-timeout','request-disconnect',
    'return-incomplete','return-timeout','return-nonzero','return-old-boot','return-not-completed')) {
    $case | Set-Content (Join-Path $root 'mode.txt')
    [IO.File]::WriteAllText((Join-Path $root 'calls.txt'),'')
    $failed=$false
    try { & (Join-Path $scripts 'Test-MiboxSoftwareReturn.ps1') -AndroidBaseline $baseline -Candidate Capture -TimeoutSeconds 10 | Out-Null }
    catch {$failed=$true}
    $identityFailure=$case -like 'identity-*'
    $latest=Get-ChildItem (Join-Path $root 'artifacts/software-return') -Directory | Sort-Object Name | Select-Object -Last 1
    $record=Get-Content -Raw (Join-Path $latest.FullName 'result.json') | ConvertFrom-Json
    $calls=@(Get-Content (Join-Path $root 'calls.txt'))
    $requests=@($calls | Where-Object {$_ -match 'reboot-android --boot-id'}).Count
    $queries=@($calls | Where-Object {$_ -match 'getprop'}).Count
    $expectedRequests=if($identityFailure){0}else{1}
    $pass=$failed -eq $identityFailure -and $requests -eq $expectedRequests
    if(-not $identityFailure) {$pass=$pass -and $record.PhysicalAndroidReturnVerified}
    if($case -like 'return-*') {$pass=$pass -and $queries -eq 2}
    $results += [pscustomobject]@{Case=$case;Pass=[bool]$pass;RestartRequests=$requests;AndroidQueries=$queries}
    $results | ConvertTo-Json | Set-Content (Join-Path $root 'results.json')
    if(-not $pass) {throw "Return fixture failed: $case; $root"}
    # Original evidence folders have second-resolution names.
    Start-Sleep -Milliseconds 1100
}
Write-Output "SOFTWARE_RETURN_PASS: $($results.Count) cases; fake ADB only; Evidence: $root"
