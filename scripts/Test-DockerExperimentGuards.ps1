# Local-only; no USB, ADB or device reboot operations.
param([ValidateSet('DockerKernel','DockerKernel2')][string]$Candidate='DockerKernel2')
$ErrorActionPreference='Stop'
$loader=Join-Path $PSScriptRoot 'Test-MiboxLoaderRam.ps1'
$local=& $loader -Action UploadAndBoot -Candidate $Candidate -VerifyOnly | ConvertFrom-Json
if($local.UsbAccessed -ne $false -or $local.Bytes -ne 8388608) {throw 'Local-only proof failed'}
$directory=if($Candidate -eq 'DockerKernel2') {'mibox-boot-candidate-docker2'} else {'mibox-boot-candidate-docker'}
$path=Join-Path $PSScriptRoot ("../target/$directory/boot1-custom.NOT_READY.img")
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
Must-Reject 'modified-image' { [MiboxLoader.RamTest]::ValidateImage($modified,$Candidate) } 'Candidate hash/size mismatch'
Must-Reject 'truncated-image' { [MiboxLoader.RamTest]::ValidateImage([byte[]]@(0),$Candidate) } 'Candidate hash/size mismatch'
Must-Reject 'wrong-preset' { [MiboxLoader.RamTest]::ValidateImage($image,'ContainerKernel2') } 'Candidate hash/size mismatch'
Must-Reject 'boot-without-full-upload' { & $loader -Action BootCandidate -Candidate $Candidate -VerifyOnly } 'full upload/readback/boot'
Must-Reject 'bulk-image-action' { & $loader -Action UploadAndBoot -Candidate $Candidate -VerifyOnly -Bulk } 'Bulk image actions disabled'
Write-Output 'DOCKER_EXPERIMENT_GUARDS_PASS (no device access)'
