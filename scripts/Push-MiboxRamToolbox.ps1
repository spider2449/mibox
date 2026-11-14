param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=Join-Path $repo 'phone-tools/platform-tools/adb.exe'
$start.Arguments='-s 248243005297 shell cat /etc/os-release'
$start.UseShellExecute=$false; $start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
$process=[Diagnostics.Process]::new(); $process.StartInfo=$start
try {
    [void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(5000)) {$process.Kill(); $process.WaitForExit(); throw 'Custom rootfs check timed out'}
    $process.WaitForExit()
    if($process.ExitCode -ne 0 -or $stdout.Result -notmatch '(?m)^ID=mibox-custom\s*$') {
        throw 'Custom RAM rootfs required; no executable sent'
    }
} finally {$process.Dispose()}
$source=Join-Path $repo 'target/armv7-unknown-linux-musleabihf/release/mibox-userland'
$bytes=[IO.File]::ReadAllBytes($source)
if($bytes.Length -gt 4194304 -or $bytes.Length -lt 52 -or
   [BitConverter]::ToString($bytes[0..5]) -ne '7F-45-4C-46-01-01' -or
   [BitConverter]::ToUInt16($bytes,18) -ne 40) {throw 'Expected bounded ARM ELF32 little-endian toolbox'}
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
$destination='/tmp/mibox-toolbox-'+$hash.Substring(0,12)
# Use the existing authenticated ADB server. The classic sync SEND mode is
# explicit because the minimal rootfs has no external chmod program.
# Reference: AOSP android-4.4.2_r1/adb/file_sync_service.c, do_send.
$client=[Net.Sockets.TcpClient]::new()
$client.ReceiveTimeout=5000; $client.SendTimeout=5000
try {
    $connect=$client.ConnectAsync('127.0.0.1',5037)
    if(-not $connect.Wait(5000)) {throw 'Local ADB server connect timed out'}
    $stream=$client.GetStream()
    function Read-Exact([int]$Length) {
        $buffer=New-Object byte[] $Length; $offset=0
        while($offset -lt $Length) {
            $count=$stream.Read($buffer,$offset,$Length-$offset)
            if($count -le 0){throw 'ADB connection closed'}
            $offset+=$count
        }
        return ,$buffer
    }
    function Send-Service([string]$Name) {
        $payload=[Text.Encoding]::ASCII.GetBytes($Name)
        $prefix=[Text.Encoding]::ASCII.GetBytes(('{0:x4}' -f $payload.Length))
        $stream.Write($prefix,0,4); $stream.Write($payload,0,$payload.Length)
        $status=[Text.Encoding]::ASCII.GetString((Read-Exact 4))
        if($status -ne 'OKAY'){throw ('ADB service rejected: '+$Name+' '+$status)}
    }
    function Send-Packet([string]$Id,[byte[]]$Data,[uint32]$Value) {
        $header=New-Object byte[] 8
        [Text.Encoding]::ASCII.GetBytes($Id).CopyTo($header,0)
        [BitConverter]::GetBytes($Value).CopyTo($header,4)
        $stream.Write($header,0,8)
        if($Data.Length){$stream.Write($Data,0,$Data.Length)}
    }
    Send-Service 'host:transport:248243005297'
    Send-Service 'sync:'
    $name=[Text.Encoding]::UTF8.GetBytes($destination+',33261') # regular file 0755
    Send-Packet 'SEND' $name $name.Length
    for($offset=0;$offset -lt $bytes.Length;$offset+=65536) {
        $length=[Math]::Min(65536,$bytes.Length-$offset)
        $chunk=New-Object byte[] $length
        [Array]::Copy($bytes,$offset,$chunk,0,$length)
        Send-Packet 'DATA' $chunk $length
    }
    Send-Packet 'DONE' @() ([uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $reply=Read-Exact 8
    $status=[Text.Encoding]::ASCII.GetString($reply,0,4)
    $length=[BitConverter]::ToUInt32($reply,4)
    if($status -ne 'OKAY') {
        if($length -gt 4096){throw 'Invalid sync failure length'}
        $reason=[Text.Encoding]::UTF8.GetString((Read-Exact $length))
        throw ('ADB sync failed: '+$reason)
    }
    if($length -ne 0){throw 'Unexpected sync success payload'}
    Send-Packet 'QUIT' @() 0
    [ordered]@{Source=$source;Destination=$destination;Bytes=$bytes.Length;Sha256=$hash;Mode='0755';Location='RAM /tmp'} | ConvertTo-Json
} finally {$client.Dispose()}
