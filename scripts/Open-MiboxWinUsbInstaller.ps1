param([switch]$RequirePresent)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$folder=Join-Path $repo 'phone-tools/driver-tools'
$tool=Join-Path $folder 'zadig-2.9.exe'
$preset=Join-Path $folder 'mibox-loader.cfg'
$sourcePreset=Join-Path $repo 'assets/host-driver/mibox-loader.cfg'
$expected='4ECAA95DF3DA3621486A043AEF8B3050B8BAFE7C901402871E816229EF82039B'
if((Get-FileHash -LiteralPath $tool).Hash -ne $expected) {throw 'Installer differs from verified official download'}
$signature=Get-AuthenticodeSignature -LiteralPath $tool
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Akeo Consulting') {throw 'Installer publisher signature not valid'}
$configuration=Get-Content -LiteralPath $sourcePreset -Raw
if($configuration -notmatch 'VID = 0x1B8E' -or $configuration -notmatch 'PID = 0xC003' -or $configuration -notmatch '86C80ED9-6F95-4FB7-ABFE-744BA77DDC25') {throw 'Device preset differs from scoped loader profile'}
Copy-Item -LiteralPath $sourcePreset -Destination $preset -Force
if($RequirePresent -and -not @(Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match '^USB\\VID_1B8E&PID_C003\\'}).Count) {throw 'Exact loader must be present before opening this installer'}
Write-Output 'Windows UAC approval is required for driver installation.'
Write-Output 'In Zadig: Device > Load Preset Device, select this file:'
Write-Output $preset
Write-Output 'Verify USB ID 1B8E C003 and driver WinUSB, then Install Driver.'
# Visible intentionally: this is the interactive installer the owner must control.
$process=Start-Process -FilePath $tool -WorkingDirectory $folder -Verb RunAs -PassThru
Write-Output "INSTALLER_PROCESS_ID=$($process.Id)"
