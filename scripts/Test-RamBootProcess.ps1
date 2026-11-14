# Host-only fixtures exercising the exact runner used by ram-boot.ps1.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'RamBootProcess.ps1')
$evidence=Join-Path $repo ('artifacts/ram-boot/process-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $evidence | Out-Null
$fixtureRoot=Join-Path $repo ('target/ram-boot-process-tests/'+[guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$fixture=Join-Path $fixtureRoot 'fixture.ps1'
@'
param($Mode,$ChildRecord)
if($Mode -eq 'tree' -or $Mode -eq 'pipe') {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $PSHOME 'powershell.exe'
    $info.Arguments='-NoProfile -Command "Start-Sleep -Seconds 45"'
    if($Mode -eq 'pipe') {$info.Arguments='-NoProfile -Command "Start-Sleep -Seconds 10"'}
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $child=[Diagnostics.Process]::Start($info)
    @{Pid=$child.Id;StartedAt=$child.StartTime.ToUniversalTime().ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath $ChildRecord
}
Write-Output 'fixture-started'
[Console]::Error.WriteLine('fixture-stderr')
if($Mode -eq 'pipe') {exit 0}
Start-Sleep -Seconds 45
'@ | Set-Content -Encoding UTF8 -LiteralPath $fixture
$results=@()
foreach($case in @('exit-zero','exit-seven','launch-failure','timeout','tree-timeout','inherited-pipes')) {
    $childRecord=Join-Path $fixtureRoot 'child.json'
    $exe=Join-Path $env:SystemRoot 'System32/cmd.exe'
    $arguments='/d /c exit 0';$deadline=5
    switch($case) {
        'exit-seven' {$arguments='/d /c exit 7'}
        'launch-failure' {$exe=Join-Path $fixtureRoot 'absent.exe'}
        'timeout' {
            $exe=Join-Path $PSHOME 'powershell.exe'
            $arguments="-NoProfile -File `"$fixture`" -Mode sleep";$deadline=2
        }
        'tree-timeout' {
            $exe=Join-Path $PSHOME 'powershell.exe'
            $arguments="-NoProfile -File `"$fixture`" -Mode tree -ChildRecord `"$childRecord`"";$deadline=3
        }
        'inherited-pipes' {
            $exe=Join-Path $PSHOME 'powershell.exe'
            $arguments="-NoProfile -File `"$fixture`" -Mode pipe -ChildRecord `"$childRecord`"";$deadline=5
        }
    }
    $failed=$false
    try {[void](Run-Process $case $exe $arguments $deadline)} catch {$failed=$true}
    $record=Get-Content -Raw -LiteralPath (Join-Path $evidence ($case+'.json')) | ConvertFrom-Json
    $pass=$false
    switch($case) {
        'exit-zero' {$pass=-not $failed -and $record.ExitCode -eq 0 -and $record.OutputComplete}
        'exit-seven' {$pass=$failed -and $record.ExitCode -eq 7 -and -not $record.TimedOut}
        'launch-failure' {$pass=$failed -and $null -eq $record.ProcessId -and $null -ne $record.Failure}
        'inherited-pipes' {
            $child=Get-Content -Raw -LiteralPath $childRecord | ConvertFrom-Json
            $live=Get-Process -Id $child.Pid -ErrorAction SilentlyContinue
            $same=$null -ne $live -and $live.StartTime.ToUniversalTime().ToString('o') -eq $child.StartedAt
            $pass=$failed -and $record.ExitCode -eq 0 -and -not $record.TimedOut -and
                -not $record.OutputComplete -and -not $record.CleanupAttempted -and
                -not $record.StdoutComplete -and -not $record.StderrComplete -and
                $record.ElapsedSeconds -lt 9 -and $same
            $record | Add-Member -NotePropertyName ChildIdentity -NotePropertyValue $child
            $record | Add-Member -NotePropertyName ChildStillRunning -NotePropertyValue ([bool]$same)
            # Retain this exact live child object; the fixture exits naturally.
            if($same -and -not $live.WaitForExit(15000)){throw 'Pipe fixture did not exit naturally'}
        }
        default {
            $pass=$failed -and $record.TimedOut -and $record.CleanupAttempted -and
                $record.CleanupExitCode -eq 0 -and $null -ne $record.ExitCode -and
                $record.OutputComplete -and $record.Output -eq 'fixture-started' -and
                $record.Error -eq 'fixture-stderr' -and $record.ElapsedSeconds -lt ($deadline+12)
            if($case -eq 'tree-timeout') {
                $child=Get-Content -Raw -LiteralPath $childRecord | ConvertFrom-Json
                $live=Get-Process -Id $child.Pid -ErrorAction SilentlyContinue
                $same=$null -ne $live -and $live.StartTime.ToUniversalTime().ToString('o') -eq $child.StartedAt
                $pass=$pass -and -not $same
                $record | Add-Member -NotePropertyName ChildIdentity -NotePropertyValue $child
                $record | Add-Member -NotePropertyName ChildStillRunning -NotePropertyValue ([bool]$same)
            }
        }
    }
    $results += [pscustomobject]@{Case=$case;Pass=[bool]$pass;Record=$record}
    $results | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence 'results.json')
    if(-not $pass){throw "Process case failed: $case; $evidence"}
}
Write-Output "RAM_BOOT_PROCESS_PASS: $($results.Count) cases; no device access; Evidence: $evidence"
