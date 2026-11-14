param(
    [string]$Serial = '248243005297',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/partitions'),
    [string]$AdbPath = (Join-Path $PSScriptRoot '../phone-tools/platform-tools/adb.exe')
)
$ErrorActionPreference = 'Stop'
$query = 'for p in bootloader reserved env logo recovery boot boot1 system system1 cache data; do echo PARTITION:$p; cat /sys/class/block/$p/dev; cat /sys/class/block/$p/start; cat /sys/class/block/$p/size; done'
$raw = & $AdbPath -s $Serial shell $query
if ($LASTEXITCODE -ne 0) { throw 'Partition query failed' }
$lines = @($raw | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($lines.Count -ne 44) { throw 'Unexpected partition output; no layout produced' }
$partitions = for ($i = 0; $i -lt $lines.Count; $i += 4) {
    if ($lines[$i] -notmatch '^PARTITION:([a-z0-9]+)$') { throw 'Missing partition marker' }
    $name = $Matches[1]
    if ($lines[$i+1] -notmatch '^\d+:\d+$' -or
        $lines[$i+2] -notmatch '^\d+$' -or $lines[$i+3] -notmatch '^\d+$') {
        throw "Invalid sysfs fields for $name"
    }
    $start = [long]$lines[$i+2]
    $sectors = [long]$lines[$i+3]
    [pscustomobject]@{
        Name=$name; Device="/dev/block/$name"; MajorMinor=$lines[$i+1]
        StartSector=$start; Sectors=$sectors
        OffsetBytes=$start*512L; SizeBytes=$sectors*512L
    }
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$raw | Set-Content (Join-Path $OutputDirectory 'sysfs-output.txt') -Encoding UTF8
[pscustomobject]@{
    Serial=$Serial; CollectedAt=(Get-Date -Format o)
    SectorUnitBytes=512; Partitions=$partitions
    Note='Read-only sysfs inventory, not raw backup or flash instructions.'
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'layout.json') -Encoding UTF8
$partitions | Format-Table Name,OffsetBytes,SizeBytes -AutoSize
