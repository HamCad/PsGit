function Read-PsGitUInt32BE {
    <# .SYNOPSIS Read a big-endian uint32 from a byte array. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][int]$Offset)
    return ([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor `
           ([uint32]$Bytes[$Offset + 2] -shl 8) -bor [uint32]$Bytes[$Offset + 3]
}

function Read-PsGitUInt64BE {
    <# .SYNOPSIS Read a big-endian uint64 from a byte array. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][int]$Offset)
    $hi = Read-PsGitUInt32BE -Bytes $Bytes -Offset $Offset
    $lo = Read-PsGitUInt32BE -Bytes $Bytes -Offset ($Offset + 4)
    return ([uint64]$hi -shl 32) -bor [uint64]$lo
}

function Find-PsGitPackOffset {
    <# .SYNOPSIS Look up an object id in a pack .idx (v2); return its .pack byte offset or $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IdxPath, [Parameter(Mandatory)][string]$Id)
    $idx = Get-PsGitFileBytesCached -Path $IdxPath
    if (-not ($idx[0] -eq 0xFF -and $idx[1] -eq 0x74 -and $idx[2] -eq 0x4F -and $idx[3] -eq 0x63)) {
        throw "Unsupported pack index (expected v2 magic): $IdxPath"
    }
    if ((Read-PsGitUInt32BE -Bytes $idx -Offset 4) -ne 2) {
        throw "Unsupported pack index version (only v2): $IdxPath"
    }
    $id = $Id.ToLowerInvariant()
    $fanoutStart = 8
    $namesStart = $fanoutStart + 256 * 4
    $n = Read-PsGitUInt32BE -Bytes $idx -Offset ($fanoutStart + 255 * 4)
    $first = [Convert]::ToByte($id.Substring(0, 2), 16)
    $lo = if ($first -eq 0) { 0 } else { Read-PsGitUInt32BE -Bytes $idx -Offset ($fanoutStart + ($first - 1) * 4) }
    $hi = Read-PsGitUInt32BE -Bytes $idx -Offset ($fanoutStart + $first * 4)
    $target = New-Object byte[] 20
    for ($k = 0; $k -lt 20; $k++) { $target[$k] = [Convert]::ToByte($id.Substring($k * 2, 2), 16) }
    $found = -1
    while ($lo -lt $hi) {
        $mid = [int][math]::Floor(($lo + $hi) / 2)
        $p = $namesStart + $mid * 20
        $cmp = 0
        for ($k = 0; $k -lt 20; $k++) { $d = $idx[$p + $k] - $target[$k]; if ($d -ne 0) { $cmp = $d; break } }
        if ($cmp -eq 0) { $found = $mid; break }
        elseif ($cmp -lt 0) { $lo = $mid + 1 } else { $hi = $mid }
    }
    if ($found -lt 0) { return $null }
    $offTableStart = $namesStart + $n * 20 + $n * 4   # after 20-byte names + 4-byte CRCs
    $offRaw = Read-PsGitUInt32BE -Bytes $idx -Offset ($offTableStart + $found * 4)
    if (($offRaw -band 0x80000000) -eq 0) { return [long]$offRaw }
    $largeStart = $offTableStart + $n * 4
    $largeIdx = $offRaw -band 0x7FFFFFFF
    return [long](Read-PsGitUInt64BE -Bytes $idx -Offset ($largeStart + $largeIdx * 8))
}

function Resolve-PsGitPackId {
    <# .SYNOPSIS Return all full ids in any pack index whose names start with Prefix. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Prefix)
    $prefix = $Prefix.ToLowerInvariant()
    $packDir = Join-Path $RepoPath '.git\objects\pack'
    if (-not (Test-Path -LiteralPath $packDir)) { return @() }
    $first = [Convert]::ToByte($prefix.Substring(0, 2), 16)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($idxPath in [System.IO.Directory]::EnumerateFiles($packDir, '*.idx')) {
        $idx = Get-PsGitFileBytesCached -Path $idxPath
        if (-not ($idx[0] -eq 0xFF -and (Read-PsGitUInt32BE -Bytes $idx -Offset 4) -eq 2)) { continue }
        $fanoutStart = 8; $namesStart = $fanoutStart + 256 * 4
        $lo = if ($first -eq 0) { 0 } else { Read-PsGitUInt32BE -Bytes $idx -Offset ($fanoutStart + ($first - 1) * 4) }
        $hi = Read-PsGitUInt32BE -Bytes $idx -Offset ($fanoutStart + $first * 4)
        for ($m = $lo; $m -lt $hi; $m++) {
            $name = Get-PsGitHexLower -Bytes $idx -Offset ($namesStart + $m * 20) -Count 20
            if ($name.StartsWith($prefix)) { $found.Add($name) }
        }
    }
    return $found.ToArray()
}
