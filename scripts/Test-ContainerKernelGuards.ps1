# Local-only validation: never opens USB, starts ADB or changes the image file.
$ErrorActionPreference='Stop'
$loader=Join-Path $PSScriptRoot 'Test-MiboxLoaderRam.ps1'
$local=& $loader -Action UploadAndBoot -Candidate ContainerKernel2 -VerifyOnly | ConvertFrom-Json
if($local.UsbAccessed -ne $false -or $local.Bytes -ne 8388608) {throw 'Local-only image proof failed'}
$path=Join-Path $PSScriptRoot '../target/mibox-boot-candidate-kernel2/boot1-custom.NOT_READY.img'
$image=[IO.File]::ReadAllBytes((Resolve-Path $path))
function Must-Reject([string]$Name,[scriptblock]$Body,[string]$Expected) {
    $rejected=$false
    try { & $Body | Out-Null } catch {
        if($_.Exception.Message -notmatch $Expected) {throw}
        $rejected=$true
    }
    if(-not $rejected) {throw "$Name unexpectedly passed"}
    Write-Output "$Name PASS"
}
$modified=[byte[]]$image.Clone();$modified[0]=$modified[0] -bxor 1
Must-Reject 'modified-image' { [MiboxLoader.RamTest]::ValidateImage($modified,'ContainerKernel2') } 'Candidate hash/size mismatch'
Must-Reject 'truncated-image' { [MiboxLoader.RamTest]::ValidateImage([byte[]]@(0),'ContainerKernel2') } 'Candidate hash/size mismatch'
Must-Reject 'wrong-preset' { [MiboxLoader.RamTest]::ValidateImage($image,'Restart') } 'Candidate hash/size mismatch'
Must-Reject 'boot-without-full-upload' { & $loader -Action BootCandidate -Candidate ContainerKernel2 -VerifyOnly } 'full upload/readback/boot'
Must-Reject 'bulk-image-action' { & $loader -Action UploadAndBoot -Candidate ContainerKernel2 -VerifyOnly -Bulk } 'Bulk image actions disabled'
Write-Output 'CONTAINER_KERNEL_GUARDS_PASS (no device access)'
