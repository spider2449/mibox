param(
    [string]$Output = 'artifacts/restoration/2026-11-14/backup-verification.json'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$records = [System.Collections.Generic.List[object]]::new()
function Check-Image([string]$Path, [long]$Bytes, [string]$Hash) {
    $item = Get-Item -LiteralPath $Path
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $ok = $item.Length -eq $Bytes -and $actual -ceq $Hash
    $records.Add([pscustomobject]@{
        File = $Path.Substring($repo.Length + 1).Replace('\', '/')
        Bytes = $item.Length; ExpectedBytes = $Bytes
        SHA256 = $actual; ExpectedSHA256 = $Hash; Match = $ok
    })
}
$boot = Get-Content -Raw -LiteralPath (Join-Path $repo 'artifacts/boot-evidence/2026-11-13/verified-backups.json') | ConvertFrom-Json
foreach ($entry in $boot) {
    if ($entry.DeviceMatch -ne $true) { throw 'Missing historical device match' }
    Check-Image (Join-Path $repo "phone-tools/backup/2026-11-13/$($entry.File)") $entry.Bytes $entry.SHA256
}
$systems = Get-Content -Raw -LiteralPath (Join-Path $repo 'artifacts/system-backups/2026-11-14/verified-systems.json') | ConvertFrom-Json
foreach ($entry in $systems) {
    if ($entry.SHA256 -cne $entry.DeviceSHA256) { throw 'Historical device hash mismatch' }
    # Resolve the retained repo-relative suffix rather than trusting an absolute manifest path.
    $relative = ($entry.Image -replace '\\', '/') -split 'phone-tools/backup/', 2
    if ($relative.Count -ne 2) { throw 'Unrecognized backup path' }
    $image = [IO.Path]::GetFullPath((Join-Path $repo "phone-tools/backup/$($relative[1])"))
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $repo 'phone-tools/backup')) + [IO.Path]::DirectorySeparatorChar
    if (-not $image.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup path escapes root' }
    Check-Image $image $entry.Bytes $entry.SHA256
    $offset = 0L
    $index = 0
    foreach ($chunk in $entry.Chunks) {
        if ($chunk.Offset -ne $offset -or $chunk.Index -ne $index -or $chunk.Bytes -le 0) { throw 'Invalid chunk coverage' }
        if ([IO.Path]::GetFileName($chunk.File) -cne $chunk.File) { throw 'Invalid chunk filename' }
        Check-Image (Join-Path (Split-Path $image -Parent) $chunk.File) $chunk.Bytes $chunk.SHA256
        $offset += $chunk.Bytes
        $index++
    }
    if ($offset -ne $entry.Bytes) { throw 'Incomplete chunk coverage' }
}
$passed = @($records | Where-Object { -not $_.Match }).Count -eq 0
$result = [ordered]@{
    ObservedAt = (Get-Date).ToString('o'); LocalIntegrityPass = $passed
    DeviceAccess = $false; RestorationTested = $false
    PermanentInstallReadiness = 'NOT READY'; Files = @($records.ToArray())
    Excluded = @('mmcblk0boot0.INCOMPLETE.img', 'unrecorded zero-byte system.img')
    Limits = 'Local hashes compared with historical device-verified manifests; no current device or restore validation.'
}
$destination = Join-Path $repo $Output
New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $destination
if (-not $passed) { throw "Backup mismatch; see $destination" }
Write-Output "LOCAL_BACKUP_INTEGRITY_PASS: $($records.Count) files; restoration NOT TESTED"
