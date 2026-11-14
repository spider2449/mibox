# Shared retained-process runner. Caller supplies $repo and $evidence.
function Run-Process([string]$Name, [string]$Executable, [string]$Arguments, [int]$DeadlineSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable; $start.Arguments = $Arguments
    $start.WorkingDirectory = $repo
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{ Executable=$Executable; Arguments=$Arguments; WorkingDirectory=$repo
        DeadlineSeconds=$DeadlineSeconds; ProcessId=$null; StartedAt=$null; ExitCode=$null
        TimedOut=$false; OutputComplete=$false; Output=''; Error=''; CleanupAttempted=$false }
    try {
        [void]$process.Start()
        $result.ProcessId = $process.Id
        $result.StartedAt = $process.StartTime.ToUniversalTime().ToString('o')
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $nextNotice = 30
        while (-not $process.WaitForExit(200)) {
            if ($clock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
                $result.TimedOut = $true
                # The retained root is still alive here. Do not target historical PIDs.
                if (-not $process.HasExited) {
                    $result.CleanupAttempted = $true
                    $killStart = [Diagnostics.ProcessStartInfo]::new()
                    $killStart.FileName = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                    $killStart.Arguments = '/PID ' + $process.Id + ' /T /F'
                    $killStart.UseShellExecute=$false; $killStart.CreateNoWindow=$true
                    $killStart.RedirectStandardOutput=$true; $killStart.RedirectStandardError=$true
                    $killer = [Diagnostics.Process]::new(); $killer.StartInfo=$killStart
                    try {
                        [void]$killer.Start()
                        $killOut=$killer.StandardOutput.ReadToEndAsync()
                        $killErr=$killer.StandardError.ReadToEndAsync()
                        if (-not $killer.WaitForExit(5000)) {
                            $killer.Kill()
                            throw 'Process-tree cleanup exceeded 5 seconds'
                        }
                        $result.CleanupExitCode=$killer.ExitCode
                    } finally { $killer.Dispose() }
                }
                break
            }
            if ($clock.Elapsed.TotalSeconds -ge $nextNotice) {
                Write-Host ("{0}: {1}s elapsed" -f $Name, [int]$clock.Elapsed.TotalSeconds)
                $nextNotice += 30
            }
        }
        if (-not $process.WaitForExit(5000)) { throw 'Child did not exit after cleanup' }
        $result.ExitCode = $process.ExitCode
        # Descendants can inherit pipes: never wait indefinitely for EOF.
        $result.StdoutComplete = $stdout.Wait(2000)
        $result.StderrComplete = $stderr.Wait(2000)
        $result.OutputComplete = $result.StdoutComplete -and $result.StderrComplete
        if ($stdout.IsCompleted) { $result.Output=$stdout.Result.Trim() }
        if ($stderr.IsCompleted) { $result.Error=$stderr.Result.Trim() }
        if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not $result.OutputComplete) {
            throw "$Name failed; no automatic retry. Evidence: $evidence"
        }
        return $result
    } catch {
        $result.Failure=$_.Exception.Message
        throw
    } finally {
        $result.ElapsedSeconds=$clock.Elapsed.TotalSeconds
        $result.FinishedAt=[DateTime]::UtcNow.ToString('o')
        $result | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidence ($Name + '.json'))
        $process.Dispose()
    }
}
