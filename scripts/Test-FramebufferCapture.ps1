# Isolated orchestration fixtures: fake ADB, actual host PNG converter.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$root=Join-Path $repo ('target/framebuffer-capture-tests/'+[guid]::NewGuid().ToString())
$scripts=Join-Path $root 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
foreach($file in @('Capture-MiboxFramebuffer.ps1','framebuffer_ppm.py')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $scripts
}
(Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'RamBootProcess.ps1')).Replace(
    'function Run-Process(', 'function Real-Run-Process(') |
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $scripts 'RealRamBootProcess.ps1')
@'
. (Join-Path $PSScriptRoot 'RealRamBootProcess.ps1')
function Run-Process($Name,$Executable,$Arguments,$DeadlineSeconds) {
    if($Name -eq 'convert'){return Real-Run-Process $Name $Executable $Arguments $DeadlineSeconds}
    $mode=(Get-Content -Raw -LiteralPath (Join-Path $repo 'mode.txt')).Trim()
    $boot='49c3b52c-4d60-4bbc-9eac-8a502088108c'
    $output=''
    switch($Name) {
        'os' {$output='ID=mibox-custom'}
        'boot-before' {$output=$boot}
        'boot-after' {$output=$boot;if($mode -eq 'changed-boot'){$output='00000000-0000-0000-0000-000000000000'}}
        'ready-before' {$output='MIBOX_RESTART_READY boot_id='+$boot}
        'ready-after' {$output='MIBOX_RESTART_READY boot_id='+$boot}
        'capture' {
            $output="MIBOX_FRAMEBUFFER_CAPTURE path=/dev/mibox-framebuffer.ppm width=1 height=1 format=P6 scope=framebuffer_only`nMIBOX_HARDWARE_EXIT=0`nMIBOX_COMMAND_EXIT=0"
            if($mode -like 'display-*') {
                if($Arguments -notmatch 'hardware-test display --boot-id'){throw 'Display action required'}
                $output="MIBOX_FRAMEBUFFER_CAPTURE path=/dev/mibox-framebuffer.ppm width=8 height=1 format=P6 scope=framebuffer_only`nframebuffer_restore=ok`nMIBOX_HDMI_PATTERN_WRITTEN owner_visual_confirmation=required`nMIBOX_HARDWARE_EXIT=0`nMIBOX_COMMAND_EXIT=0"
            }
            if($mode -eq 'helper-failed'){$output='MIBOX_HARDWARE_EXIT=1'}
        }
        'pull-capture' {
            $bytes=[Text.Encoding]::ASCII.GetBytes("P6`n1 1`n255`nABC")
            if($mode -eq 'bad-ppm'){$bytes=[byte[]]@(0,1,2)}
            if($mode -like 'display-*') {
                $bytes=[Text.Encoding]::ASCII.GetBytes("P6`n8 1`n255`n") + [byte[]]@(255,255,255,255,255,0,0,255,255,0,255,0,255,0,255,255,0,0,0,0,255,0,0,0)
                if($mode -eq 'display-wrong-pixel'){$bytes[-1]=1}
            }
            [IO.File]::WriteAllBytes((Join-Path $evidence 'framebuffer.ppm'),$bytes)
        }
        default {
            if($Name -notmatch '^pull-(init|mibox|helper)$'){throw ('Unexpected fixture call: '+$Name)}
            $value='fixture'
            if($mode -eq 'wrong-pin'){$value='changed'}
            [IO.File]::WriteAllText((Join-Path $evidence ($Matches[1]+'.elf')),$value)
        }
    }
    $record=[ordered]@{ExitCode=0;OutputComplete=$true;TimedOut=$false;Output=$output}
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence ($Name+'.json'))
    return [pscustomobject]$record
}
'@ | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $scripts 'RamBootProcess.ps1')
$binary=Join-Path $root 'fixture.bin'
[IO.File]::WriteAllText($binary,'fixture')
$hash=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=Join-Path $root 'manifest.json'
@{files=@{init=@{sha256=$hash};'bin/mibox'=@{sha256=$hash};'sbin/mibox-hardware'=@{sha256=$hash}}} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest
$results=@()
foreach($case in @('valid','wrong-pin','helper-failed','bad-ppm','changed-boot','display-valid','display-wrong-pixel')) {
    $case | Set-Content -LiteralPath (Join-Path $root 'mode.txt')
    $failed=$false
    try {& (Join-Path $scripts 'Capture-MiboxFramebuffer.ps1') -ManifestPath $manifest -DisplayPattern:($case -like 'display-*') | Out-Null}
    catch {$failed=$true}
    $latest=Get-ChildItem -LiteralPath (Join-Path $root 'artifacts/framebuffer-capture') -Directory |
        Sort-Object Name | Select-Object -Last 1
    $record=Get-Content -Raw -LiteralPath (Join-Path $latest.FullName 'result.json') | ConvertFrom-Json
    $expected=$case -in @('valid','display-valid')
    $pass=$record.CaptureVerified -eq $expected -and $failed -ne $expected -and -not $record.HdmiScanoutVerified
    if($case -eq 'wrong-pin'){$pass=$pass -and -not (Test-Path -LiteralPath (Join-Path $latest.FullName 'capture.json'))}
    if($case -eq 'helper-failed'){$pass=$pass -and -not (Test-Path -LiteralPath (Join-Path $latest.FullName 'pull-capture.json'))}
    $results += [pscustomobject]@{Case=$case;Pass=[bool]$pass;Record=$record}
    $results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'results.json')
    if(-not $pass){throw "Capture fixture failed: $case; $root"}
}
Write-Output "FRAMEBUFFER_CAPTURE_GUARDS_PASS: $($results.Count) cases; fake ADB only; Evidence: $root"
