# Pure record validators, shared by the orchestrator and device-free tests.
function Assert-RamBootRecord($Record, [string]$Kind, [string]$ImageHash, [string]$PreviousBootId) {
    if ($null -eq $Record -or $Record -is [array] -or $Record -isnot [pscustomobject]) {
        throw "$Kind result must be one JSON object"
    }
    function Require-Bool($Value, [bool]$Expected) {
        if ($Value -isnot [bool] -or $Value -ne $Expected) { throw "$Kind boolean evidence missing or invalid" }
    }
    function Require-Size($Value) {
        if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -ne 8388608) {
            throw "$Kind byte count missing or invalid"
        }
    }
    switch ($Kind) {
        'Local' {
            Require-Bool $Record.UsbAccessed $false
            Require-Size $Record.Bytes
            if ($Record.Sha256 -cne $ImageHash) { throw 'Local image hash mismatch' }
        }
        'Transfer' {
            Require-Size $Record.VerifiedBytes
            if ($Record.VerifiedSha256 -cne $ImageHash) { throw 'RAM readback hash mismatch' }
            Require-Bool $Record.CommandAttempted $true
            Require-Bool $Record.BulkMode $false
        }
        'Custom' {
            Require-Bool $Record.CustomOsMarkerObserved $true
            foreach ($name in @('osRelease','pid1','bootId')) {
                $query = $Record.Proof.$name
                Require-Bool $query.TimedOut $false
                if ($null -eq $query.ExitCode -or $query.ExitCode -ne 0) { throw "Custom $name query failed" }
            }
            if ($Record.Proof.osRelease.Output -notmatch '(?m)^ID=mibox-custom\s*$' -or
                $Record.Proof.pid1.Output -cne 'init' -or
                $Record.Proof.bootId.Output -cnotmatch '\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z' -or
                $Record.Proof.bootId.Output -eq $PreviousBootId) { throw 'Independent custom boot identity not established' }
        }
        'Return' { Require-Bool $Record.PhysicalAndroidReturnVerified $true }
        default { throw "Unknown validation kind: $Kind" }
    }
}
