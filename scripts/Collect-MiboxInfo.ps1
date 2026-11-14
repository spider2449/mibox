param(
    [string]$Serial = '248243005297',
    [string]$AdbPath = (Join-Path $PSScriptRoot '..\phone-tools\platform-tools\adb.exe'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\artifacts\device-info')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $AdbPath)) { throw "ADB not found: $AdbPath" }
$state = & $AdbPath -s $Serial get-state 2>&1
if ($LASTEXITCODE -ne 0 -or ($state -join '').Trim() -ne 'device') {
    throw "USB device unavailable: $state"
}
$destination = Join-Path $OutputRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$queries = [ordered]@{
    identity = 'id; uname -a; getprop ro.product.model; getprop ro.product.board; getprop ro.hardware; getprop ro.build.fingerprint; getprop ro.build.display.id; getenforce'
    cpu = 'cat /proc/cpuinfo'
    memory = 'cat /proc/meminfo'
    storage = 'cat /proc/partitions; mount; ls -l /dev/block; ls -l /dev/block/platform/aml_sdio.0; cat /sys/block/mmcblk0/device/name; cat /sys/block/mmcblk0/size'
    boot = 'cat /default.prop; getprop ro.bootloader; getprop ro.boot.flash.locked; getprop ro.boot.verifiedbootstate; ls -l /proc/config.gz; cat /proc/cmdline'
    drivers = 'cat /proc/modules; ls -l /system/lib/modules; ls -l /sys/class/tty/ttyS0 /sys/class/tty/ttyS1 /sys/class/tty/ttyAML0; cat /system/etc/fw_env.config'
    amlogic = 'cat /sys/class/aml_store/part_table; cat /sys/class/aml_store/store_device; cat /sys/class/aml_store/version; ls -l /sys/class/aml_store'
}
$status = @()
foreach ($item in $queries.GetEnumerator()) {
    $ErrorActionPreference = 'Continue' # Windows PowerShell treats native stderr as error records.
    $result = & $AdbPath -s $Serial shell $item.Value 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $result | Set-Content -LiteralPath (Join-Path $destination ($item.Key + '.txt')) -Encoding UTF8
    $status += "query $($item.Key): exit=$code (inspect output for individual shell errors)"
}
foreach ($remote in @('/default.prop', '/ueventd.amlogic.rc', '/system/build.prop', '/system/etc/fw_env.config', '/system/etc/vold.fstab')) {
    $name = $remote.TrimStart('/').Replace('/', '_')
    $ErrorActionPreference = 'Continue'
    $result = & $AdbPath -s $Serial pull $remote (Join-Path $destination $name) 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $status += "pull ${remote}: exit=$code $($result -join ' ')"
}
$status | Set-Content -LiteralPath (Join-Path $destination 'collection-status.txt') -Encoding UTF8
$files = @(Get-ChildItem -LiteralPath $destination -File | Where-Object Name -ne 'sha256.csv')
$files | Get-FileHash -Algorithm SHA256 |
    Select-Object @{Name='File';Expression={Split-Path $_.Path -Leaf}}, Hash |
    Export-Csv -LiteralPath (Join-Path $destination 'sha256.csv') -NoTypeInformation -Encoding UTF8
Write-Output "Inventory saved: $destination"
Write-Output 'Read-only inventory only; no firmware partitions were backed up or modified.'
