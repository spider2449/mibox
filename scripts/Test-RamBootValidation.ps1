# Pure JSON fixtures; never invokes ADB, USB, or child device scripts.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RamBootValidation.ps1')
$hash = '5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa'
$oldId = '6d4f3f97-d576-4600-9c99-9d2814e07629'
$newId = '695ecb4b-717c-4b1b-8e1c-0faaeee26c2b'
$transfer = @{VerifiedBytes=8388608;VerifiedSha256=$hash;CommandAttempted=$true;BulkMode=$false}
$custom = @{CustomOsMarkerObserved=$true;Proof=@{
    osRelease=@{ExitCode=0;TimedOut=$false;Output='ID=mibox-custom'}
    pid1=@{ExitCode=0;TimedOut=$false;Output='init'}
    bootId=@{ExitCode=0;TimedOut=$false;Output=$newId}
}}
$cases = @(
    @{Name='transfer-valid';Kind='Transfer';Record=$transfer;Accept=$true},
    @{Name='custom-valid';Kind='Custom';Record=$custom;Accept=$true},
    @{Name='return-valid';Kind='Return';Record=@{PhysicalAndroidReturnVerified=$true};Accept=$true},
    @{Name='return-string';Kind='Return';Record=@{PhysicalAndroidReturnVerified='true'}},
    @{Name='return-missing';Kind='Return';Record=@{}},
    @{Name='return-false';Kind='Return';Record=@{PhysicalAndroidReturnVerified=$false}},
    @{Name='array';Kind='Transfer';Record=@($transfer,$transfer)},
    @{Name='null';Kind='Custom';Record=$null}
)
foreach ($mutation in @('missing-bulk','string-command','short-readback','wrong-hash','bulk-enabled')) {
    $record = $transfer.Clone()
    switch ($mutation) {
        'missing-bulk' { $record.Remove('BulkMode') }
        'string-command' { $record.CommandAttempted='true' }
        'short-readback' { $record.VerifiedBytes=8388607 }
        'wrong-hash' { $record.VerifiedSha256='0'*64 }
        'bulk-enabled' { $record.BulkMode=$true }
    }
    $cases += @{Name=$mutation;Kind='Transfer';Record=$record}
}
foreach ($mutation in @('empty-id','invalid-id','same-id','missing-proof','string-marker','wrong-pid1',
                        'query-timeout','query-error','missing-exit','wrong-os')) {
    $record = $custom | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    switch ($mutation) {
        'empty-id' { $record.Proof.bootId.Output='' }
        'invalid-id' { $record.Proof.bootId.Output='new-boot' }
        'same-id' { $record.Proof.bootId.Output=$oldId }
        'missing-proof' { $record.Proof=$null }
        'string-marker' { $record.CustomOsMarkerObserved='true' }
        'wrong-pid1' { $record.Proof.pid1.Output='sh' }
        'query-timeout' { $record.Proof.bootId.TimedOut=$true }
        'query-error' { $record.Proof.pid1.ExitCode=1 }
        'missing-exit' { $record.Proof.osRelease.PSObject.Properties.Remove('ExitCode') }
        'wrong-os' { $record.Proof.osRelease.Output='ID=android' }
    }
    $cases += @{Name=$mutation;Kind='Custom';Record=$record}
}
$results = foreach ($case in $cases) {
    $record = $null
    if ($null -ne $case.Record) {
        $record = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $case.Record -Depth 8)
    }
    $accepted = $false
    try { Assert-RamBootRecord $record $case.Kind $hash $oldId; $accepted=$true } catch { }
    if ($accepted -ne [bool]$case.Accept) { throw "Unexpected verdict: $($case.Name)" }
    [pscustomobject]@{Case=$case.Name;Pass=$true;Accepted=$accepted}
}
$destination = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts/ram-boot/validation-tests.json'
New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
$results | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $destination
Write-Output "RAM_BOOT_VALIDATION_PASS: $($results.Count) cases; no device access"
