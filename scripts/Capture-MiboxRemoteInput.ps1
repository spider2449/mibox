param(
    [ValidateRange(10,180)][int]$TimeoutSeconds = 120,
    [ValidateSet('Sequence','Back','Up','Down')][string]$Button = 'Sequence',
    [ValidateSet('IR','All')][string]$InputSource = 'IR'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $repo ('artifacts/remote-input/capture-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $destination | Out-Null
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$eventCount = if ($Button -eq 'Sequence') { 12 } else { 4 }
$node = if ($InputSource -eq 'IR') { ' /dev/input/event0' } else { '' }
$start.Arguments = "-s 248243005297 shell getevent -lt -c $eventCount$node"
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$began = (Get-Date).ToString('o')
[void]$process.Start()
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
Write-Output "REMOTE_CAPTURE_STARTED: $destination"
$timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
if ($timedOut) { $process.Kill() }
$process.WaitForExit()
$result = [ordered]@{ StartedAt = $began; FinishedAt = (Get-Date).ToString('o')
    Command = $start.Arguments; ExitCode = $process.ExitCode; TimedOut = $timedOut
    Output = $stdout.Result; Error = $stderr.Result; InputInjected = $false
    RequestedOwnerSequence = $(if ($Button -eq 'Sequence') { @('BACK', 'UP', 'DOWN') } else { @($Button.ToUpperInvariant()) })
    OwnerSequenceConfirmed = $false }
$process.Dispose()
$result | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $destination 'capture.json')
$result | ConvertTo-Json -Depth 4
