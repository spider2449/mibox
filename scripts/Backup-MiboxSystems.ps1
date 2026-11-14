param([ValidateSet('system','system1')][string[]]$Partitions=@('system1','system'))
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$adb=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$destination=Join-Path $repo ('phone-tools/backup/systems-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $destination | Out-Null
$evidence=Join-Path $repo 'artifacts/system-backups/2026-11-14'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
function Invoke-Adb([string]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$adb
    $start.Arguments="-s 248243005297 $Arguments"
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    [void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(150000)) {$process.Kill(); $process.WaitForExit(); $process.Dispose(); throw "ADB timed out: $Arguments"}
    $process.WaitForExit()
    $code=$process.ExitCode
    $out=$stdout.Result
    $err=$stderr.Result
    $process.Dispose()
    if($code -ne 0) {throw "ADB exit ${code}: $Arguments $err"}
    return $out.Replace("`r",'')
}
$records=@()
$existingManifest=Join-Path $evidence 'verified-systems.json'
if(Test-Path -LiteralPath $existingManifest) {$records=@(Get-Content -LiteralPath $existingManifest -Raw | ConvertFrom-Json)}
foreach($partition in $Partitions) {
    $image=Join-Path $destination ($partition+'.img')
    $output=[IO.File]::Open($image,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $chunks=@()
    try {
        for($index=0;$index -lt 8;$index++) {
            $result=Invoke-Adb "shell /data/local/tmp/mibox-backup-system $partition $index"
            $result | Set-Content (Join-Path $evidence "$partition-$index.txt") -Encoding UTF8
            if($result -notmatch 'MIBOX_SYSTEM_BACKUP_READ_OK') {throw "Device chunk failed: $result"}
            $remote=[regex]::Match($result,'(?m)^CHUNK_PATH=(/data/local/tmp/mibox-system-chunk-[0-9-]+/chunk\.img)$').Groups[1].Value
            $hash=[regex]::Match($result,'(?m)^SHA256=([0-9a-f]{64})$').Groups[1].Value
            if(-not $remote -or -not $hash) {throw 'Untrusted chunk result'}
            $local=Join-Path $destination ("$partition.$('{0:d2}' -f $index).part")
            [void](Invoke-Adb "pull $remote `"$local`"")
            if((Get-Item -LiteralPath $local).Length -ne 67108864 -or (Get-FileHash -LiteralPath $local).Hash -ine $hash) {throw 'Host/device chunk verification failed; scratch retained'}
            $inputStream=[IO.File]::OpenRead($local)
            try {$inputStream.CopyTo($output)} finally {$inputStream.Dispose()}
            $output.Flush($true)
            $chunks += [ordered]@{Index=$index;Offset=$index*67108864L;Bytes=67108864;SHA256=$hash;File=[IO.Path]::GetFileName($local)}
            # The exact scratch image was just verified on the host. Keep small logs.
            [void](Invoke-Adb "shell rm $remote")
            Write-Output "$partition chunk $($index+1)/8 verified"
        }
    } finally {$output.Dispose()}
    $whole=Invoke-Adb "shell /data/local/tmp/mibox-backup-system $partition hash"
    $whole | Set-Content (Join-Path $evidence "$partition-full-hash.txt") -Encoding UTF8
    $deviceHash=[regex]::Match($whole,'(?m)^SHA256=([0-9a-f]{64})$').Groups[1].Value
    $hostHash=(Get-FileHash -LiteralPath $image).Hash.ToLowerInvariant()
    if($whole -notmatch 'MIBOX_SYSTEM_BACKUP_READ_OK' -or -not $deviceHash -or $hostHash -ne $deviceHash -or (Get-Item -LiteralPath $image).Length -ne 536870912) {throw 'Full image host/device verification failed'}
    $records=@($records | Where-Object {$_.Partition -ne $partition})
    $records += [ordered]@{Partition=$partition;Bytes=536870912;SHA256=$hostHash;DeviceSHA256=$deviceHash;Image=$image;Chunks=$chunks}
    $records | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $destination 'manifest.json') -Encoding UTF8
    $records | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $evidence 'verified-systems.json') -Encoding UTF8
    Write-Output "$partition full image verified"
}
Write-Output "SYSTEM_BACKUPS_VERIFIED $destination"
