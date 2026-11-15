# Isolated orchestration fixtures: never opens ADB, USB or a block device.
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Utility
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('target/rescue-boot-tests/'+[guid]::NewGuid().ToString())
$scripts=Join-Path $fixture 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
foreach($file in @('rescue-boot.ps1','RamBootValidation.ps1','Probe-MiboxUsbLoader.ps1',
                   'Test-MiboxLoaderRam.ps1','Observe-MiboxRamBoot.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $scripts
}
@'
function Run-Process($Name,$Executable,$Arguments,$DeadlineSeconds) {
    $case=(Get-Content -Raw -LiteralPath (Join-Path $repo 'case.txt')).Trim()
    Add-Content -LiteralPath (Join-Path $repo 'calls.txt') -Value $Name
    $hash='4629deefd4e5e0f1902a54158ef01c7ad67156ef87946fb6d87c7070ba5da7c0'
    $data=switch($Name) {
        'local-check' { @{UsbAccessed=$false;Bytes=8388608;Sha256=$hash} }
        'loader-identify' { @{Found=$true;VidPid='1B8E:C003';IdentifyHex='00-08-00-10'} }
        'pre-upload-adb' { @{} }
        'upload-and-boot' { @{VerifiedBytes=8388608;VerifiedSha256=$hash;CommandAttempted=$true;BulkMode=$false} }
        'custom-observer' {
            @{CustomOsMarkerObserved=$true;Proof=@{
                osRelease=@{TimedOut=$false;OutputComplete=$true;ExitCode=0;Output='ID=mibox-custom'}
                pid1=@{TimedOut=$false;OutputComplete=$true;ExitCode=0;Output='init'}
                bootId=@{TimedOut=$false;OutputComplete=$true;ExitCode=0;Output='b5567c71-9f2e-4d73-9239-0a80e7120ab3'}
            }}
        }
        'pull-init' { New-Item -ItemType File -Path (Join-Path $evidence 'init.elf') | Out-Null; @{} }
        'pull-mibox' { New-Item -ItemType File -Path (Join-Path $evidence 'mibox.elf') | Out-Null; @{} }
        default {throw "unexpected process $Name"}
    }
    if($case -eq 'bad-local' -and $Name -eq 'local-check'){$data.Sha256='bad'}
    if($case -eq 'wrong-loader' -and $Name -eq 'loader-identify'){$data.IdentifyHex='00-00-00-00'}
    if($case -eq 'short-transfer' -and $Name -eq 'upload-and-boot'){$data.VerifiedBytes=64}
    if($case -eq 'bulk-transfer' -and $Name -eq 'upload-and-boot'){$data.BulkMode=$true}
    if($case -eq 'bad-runtime' -and $Name -eq 'custom-observer'){$data.Proof.pid1.Output='other'}
    if($case -eq 'incomplete-runtime' -and $Name -eq 'custom-observer'){$data.Proof.bootId.OutputComplete=$false}
    if($case -eq 'process-failure' -and $Name -eq 'loader-identify'){throw 'injected child failure'}
    if($Name -eq 'pre-upload-adb') {
        $text=if($case -eq 'stale-adb'){'248243005297 recovery'}else{'List of devices attached'}
        return [pscustomobject]@{Output=$text}
    }
    return [pscustomobject]@{Output=($data | ConvertTo-Json -Depth 8 -Compress)}
}
'@ | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $scripts 'RamBootProcess.ps1')
function Get-PnpDevice {
    param([switch]$PresentOnly,$ErrorAction)
    Add-Content -LiteralPath (Join-Path $fixture 'calls.txt') -Value 'pnp'
    $case=(Get-Content -Raw -LiteralPath (Join-Path $fixture 'case.txt')).Trim()
    if($case -eq 'absent'){return @()}
    $node=[pscustomobject]@{InstanceId='USB\VID_1B8E&PID_C003\fixture';Status='OK'}
    if($case -eq 'bad-driver'){$node.Status='Error'}
    if($case -eq 'ambiguous'){return @($node,$node)}
    return @($node)
}
function Get-FileHash {
    param($Algorithm,$LiteralPath)
    if($LiteralPath -like '*.elf') {
        $case=(Get-Content -Raw -LiteralPath (Join-Path $fixture 'case.txt')).Trim()
        $hash=if($LiteralPath -like '*init.elf'){'9333195a11b758f7531547008b927849da228ceddb41398d3d2b8bca25258438'}
            else {'e275d1d0520dc74f0043bc32e693a99b05af37a6855881681821a6e0dede4b07'}
        if($case -eq 'wrong-elf'){$hash='bad'}
        return [pscustomobject]@{Hash=$hash}
    }
    Microsoft.PowerShell.Utility\Get-FileHash -Algorithm $Algorithm -LiteralPath $LiteralPath
}
$results=@()
$cases=@('check','bad-local','absent','ambiguous','bad-driver','wrong-loader','process-failure','stale-adb',
         'short-transfer','bulk-transfer','bad-runtime','incomplete-runtime','wrong-elf','valid')
foreach($case in $cases) {
    $case | Set-Content -LiteralPath (Join-Path $fixture 'case.txt')
    '' | Set-Content -LiteralPath (Join-Path $fixture 'calls.txt')
    $action=if($case -eq 'check'){'Check'}else{'WaitAndBoot'}
    $failed=$false
    try { & (Join-Path $scripts 'rescue-boot.ps1') -Action $action -WaitSeconds 1 | Out-Null }
    catch {$failed=$true}
    if($failed -ne ($case -notin @('check','valid'))){throw "Unexpected outcome: $case"}
    $calls=@(Get-Content -LiteralPath (Join-Path $fixture 'calls.txt') | ForEach-Object { [string]$_ })
    if($case -in @('check','bad-local') -and 'pnp' -in $calls){throw 'Device access before local validation'}
    if($case -in @('bad-local','absent','ambiguous','bad-driver','wrong-loader','process-failure','stale-adb') -and
        'upload-and-boot' -in $calls){throw "Upload escaped preflight gate: $case"}
    if($case -in @('short-transfer','bulk-transfer') -and 'custom-observer' -in $calls){throw 'Boot accepted without full transfer proof'}
    $record=Get-ChildItem -LiteralPath (Join-Path $fixture 'artifacts/rescue-boot') -Directory |
        Sort-Object Name | Select-Object -Last 1
    $proof=Get-Content -Raw -LiteralPath (Join-Path $record.FullName 'result.json') | ConvertFrom-Json
    if($proof.IndependentColdEntryVerified -or $proof.FlashCommandSent -or $proof.EnvironmentWriteSent -or $proof.LoaderRequestSent){throw 'Unsupported success or mutation claim'}
    if($case -eq 'valid' -and -not $proof.CustomBootVerified){throw 'Expected runtime proof missing'}
    $results += [pscustomobject]@{Case=$case;Pass=$true;Calls=$calls}
}
$output=Join-Path $repo 'artifacts/restoration/2026-11-15/rescue-launcher-tests.json'
New-Item -ItemType Directory -Path (Split-Path $output -Parent) -Force | Out-Null
@{Scope='Isolated host orchestration fixtures; hashes and transports mocked';DeviceAccess=$false
    Passed=$results.Count;Cases=$results} | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 -LiteralPath $output
Write-Output "RESCUE_LAUNCHER_TESTS_PASS: $($results.Count); $output"
