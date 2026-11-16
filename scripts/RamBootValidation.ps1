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
            Require-Bool $Record.CommandAttempted $true
            if ($Record.BulkMode -is [bool] -and $Record.BulkMode) {
                # Bulk OUT upload: proof is the loader's own crc32 over the full
                # 8 MiB plus sampled EP0 readback, tied to the pinned source hash.
                if ($Record.VerificationMethod -cne 'BulkOutCrc32') { throw 'Bulk transfer verification method missing' }
                if ($Record.SourceSha256 -cne $ImageHash) { throw 'Bulk source image hash mismatch' }
                if ($Record.ExpectedCrc32 -cnotmatch '\A[0-9a-f]{8}\z' -or $Record.DeviceCrc32 -cne $Record.ExpectedCrc32) {
                    throw 'Bulk device crc32 mismatch'
                }
                if ($Record.CrcCommandStatus -isnot [string] -or -not $Record.CrcCommandStatus.StartsWith('success')) {
                    throw 'Bulk crc32 command status missing'
                }
                if ($Record.SampledBlocks -isnot [int] -or $Record.SampledBlocks -lt 129) { throw 'Bulk sampled readback incomplete' }
            } else {
                Require-Bool $Record.BulkMode $false
                if ($Record.VerifiedSha256 -cne $ImageHash) { throw 'RAM readback hash mismatch' }
            }
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
