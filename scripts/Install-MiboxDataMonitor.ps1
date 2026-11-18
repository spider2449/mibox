# Install (or -Remove) the S4 data free-space monitor in the persistent Alpine
# tree over SSH: /usr/local/bin/mibox-data-free and the login hook
# /etc/profile.d/90mibox-data-free.sh. Ordinary data-file writes; no partition
# or initramfs change. Refuses to overwrite a file that lacks the monitor's
# marker. Evidence: artifacts/alpine-data-monitor/<timestamp>/.
#
#   powershell -NoProfile -File scripts/Install-MiboxDataMonitor.ps1
#   powershell -NoProfile -File scripts/Install-MiboxDataMonitor.ps1 -Remove
param([switch]$Remove,
    [string]$IdentityFile=(Join-Path $env:USERPROFILE '.ssh/mibox-console'))
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$known=Join-Path $repo 'assets/ssh/mibox-persistent-known-hosts'
$sshBase=@('-i',$IdentityFile,'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
    '-o',"UserKnownHostsFile=$known",'-o','ConnectTimeout=5','root@192.168.1.222')
$evidence=Join-Path $repo ('artifacts/alpine-data-monitor/'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $evidence | Out-Null
$log=Join-Path $evidence 'install.txt'
function Note([string]$Text) { Write-Host $Text; Add-Content -LiteralPath $log -Value $Text -Encoding utf8 }
function Ssh-Run([string]$Command) {
    # Single quotes only in $Command: PowerShell 5.1 strips embedded double quotes.
    $saved=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $output=& ssh.exe @sshBase $Command 2>&1; $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$saved }
    return @{Code=$code; Text=(($output | ForEach-Object { "$_" }) -join "`n").Trim()}
}

$files=@(
    @{Local='assets/alpine/usr/local/bin/mibox-data-free'; Remote='/usr/local/bin/mibox-data-free'; Mode='755'; Marker='MIBOX_DATA_FREE_V1'},
    @{Local='assets/alpine/etc/profile.d/90mibox-data-free.sh'; Remote='/etc/profile.d/90mibox-data-free.sh'; Mode='644'; Marker='MIBOX_DATA_FREE_LOGIN_V1'}
)
if(-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {throw 'Owner SSH private key is missing'}
$id=Ssh-Run 'cat /proc/sys/kernel/random/boot_id; grep -qx MIBOX_PERSISTENT_CONSOLE_V1 /etc/mibox-persistent-root && echo IN_ALPINE'
if($id.Code -ne 0 -or $id.Text -notmatch '(?m)^[0-9a-f-]{36}$' -or $id.Text -notmatch 'IN_ALPINE') {
    throw "SSH did not reach the persistent Alpine tree: $($id.Text)"
}
Note "boot $(($id.Text -split "`n")[0]) action=$(if($Remove){'remove'}else{'install'})"

foreach($f in $files) {
    $remote=$f.Remote
    $existing=Ssh-Run "if [ -L $remote ]; then echo LINK; elif [ -e $remote ]; then grep -q $($f.Marker) $remote && echo OURS || echo FOREIGN; sha256sum $remote; else echo ABSENT; fi"
    if($existing.Code -ne 0) {throw "Cannot inspect ${remote}: $($existing.Text)"}
    Note "$remote before: $($existing.Text -replace "`n",' ')"
    if($existing.Text -match '^(LINK|FOREIGN)') {throw "$remote exists and is not the monitor's file; refusing to touch it."}
    if($Remove) {
        if($existing.Text -match '^OURS') {
            $r=Ssh-Run "rm -f $remote && echo REMOVED"
            if($r.Text -notmatch 'REMOVED') {throw "Remove failed for ${remote}: $($r.Text)"}
            Note "$remote removed"
        }
        continue
    }
    $text=[IO.File]::ReadAllText((Join-Path $repo $f.Local)).Replace("`r`n","`n")
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)
    $sha=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-','').ToLower()
    if($existing.Text -match $sha) { Note "$remote already current ($sha)"; continue }
    $b64=[Convert]::ToBase64String($bytes)
    $dir=Split-Path $remote -Parent | ForEach-Object { $_.Replace('\','/') }
    $r=Ssh-Run "mkdir -p $dir && test ! -L $dir && echo $b64 | base64 -d > $remote.new && chmod $($f.Mode) $remote.new && mv $remote.new $remote && sync && sha256sum $remote"
    if($r.Code -ne 0 -or $r.Text -notmatch "^$sha ") {throw "Upload of $remote failed or hash differs (expected $sha): $($r.Text)"}
    Note "$remote installed $sha mode $($f.Mode)"
}

if(-not $Remove) {
    $check=Ssh-Run '/usr/local/bin/mibox-data-free; echo EXIT=$?'
    Note "mibox-data-free: $($check.Text -replace "`n",' | ')"
    # Non-interactive login shell: the hook runs and must not end the session.
    $login=Ssh-Run 'ash -l -c ''echo LOGIN_SHELL_OK'''
    Note "login shell: $($login.Text -replace "`n",' | ')"
    if($check.Text -notmatch 'STATE=' -or $login.Text -notmatch 'LOGIN_SHELL_OK') {throw 'Post-install check failed; see the evidence log.'}
}
Note "MIBOX_DATA_MONITOR_$(if($Remove){'REMOVED'}else{'INSTALLED'})"
Write-Host "Evidence: $evidence"
