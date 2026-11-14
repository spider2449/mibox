# Isolated observer fixtures; no ADB or USB calls.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$root=Join-Path $repo ('target/ram-boot-observer-tests/'+[guid]::NewGuid().ToString())
$scripts=Join-Path $root 'scripts'
New-Item -ItemType Directory -Path $scripts -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Observe-MiboxRamBoot.ps1') -Destination $scripts
@'
function Run-Process($Name,$Executable,$Arguments,$DeadlineSeconds) {
    $mode=Get-Content -Raw -LiteralPath (Join-Path $repo 'mode.txt')
    $output='fixture'
    if($Arguments -eq 'devices -l'){$output='248243005297 recovery'}
    if($Arguments -match '/etc/os-release'){$output='ID=mibox-custom'}
    if($Arguments -match '/proc/1/comm'){$output='mibox-init'}
    if($Arguments -match '/boot_id'){$output='49c3b52c-4d60-4bbc-9eac-8a502088108c'}
    $record=[ordered]@{ExitCode=0;TimedOut=$false;OutputComplete=$true;Output=$output;Error=''}
    if($Arguments -match '/etc/os-release') {
        switch($mode.Trim()) {
            'exit-seven' {$record.ExitCode=7}
            'incomplete' {$record.OutputComplete=$false}
            'timeout' {$record.TimedOut=$true}
        }
    }
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence ($Name+'.json'))
    if($record.ExitCode -ne 0 -or $record.TimedOut -or -not $record.OutputComplete){throw 'Fixture process failure'}
    return $record
}
'@ | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $scripts 'RamBootProcess.ps1')
function Get-PnpDevice { param([switch]$PresentOnly,$ErrorAction) return @() }
$results=@()
foreach($case in @('valid','exit-seven','incomplete','timeout')) {
    $case | Set-Content -LiteralPath (Join-Path $root 'mode.txt')
    $json=& (Join-Path $scripts 'Observe-MiboxRamBoot.ps1') -TimeoutSeconds 1
    $record=($json -join "`n") | ConvertFrom-Json
    $expected=$case -eq 'valid'
    if($record.CustomOsMarkerObserved -ne $expected){throw "Observer fixture failed: $case"}
    $results += [pscustomobject]@{Case=$case;Pass=$true;CustomOsMarkerObserved=$record.CustomOsMarkerObserved}
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'results.json')
Write-Output "RAM_BOOT_OBSERVER_PASS: $($results.Count) cases; no device access; Evidence: $root"
