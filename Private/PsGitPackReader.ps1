$script:psGitPackTypeNames = @{ 1 = 'commit'; 2 = 'tree'; 3 = 'blob'; 4 = 'tag' }

function Expand-PsGitZlib {
    <# .SYNOPSIS Inflate exactly ExpectedSize bytes from a zlib stream at Buffer[Offset..]. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Buffer, [Parameter(Mandatory)][int]$Offset, [Parameter(Mandatory)][int]$ExpectedSize)
    $out = Expand-PsGitZlibBytes -Buffer $Buffer -Offset $Offset
    if ($out.Length -ne $ExpectedSize) { throw "Zlib underflow: expected $ExpectedSize bytes, got $($out.Length)." }
    return $out
}

function Invoke-PsGitDelta {
    <# .SYNOPSIS Apply a git delta (base-size, result-size, copy/insert ops) to Base. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Base, [Parameter(Mandatory)][byte[]]$Delta)
    $i = 0
    do { $b = $Delta[$i]; $i++ } while ($b -band 0x80)                # consume base-size varint
    $shift = 0; $rsize = [long]0
    do { $b = $Delta[$i]; $i++; $rsize = $rsize -bor ([long]($b -band 0x7f) -shl $shift); $shift += 7 } while ($b -band 0x80)
    $out = [System.IO.MemoryStream]::new()
    while ($i -lt $Delta.Length) {
        $op = $Delta[$i]; $i++
        if ($op -band 0x80) {
            $cpOff = [long]0; $cpSize = [long]0
            if ($op -band 0x01) { $cpOff = $cpOff -bor [long]$Delta[$i]; $i++ }
            if ($op -band 0x02) { $cpOff = $cpOff -bor ([long]$Delta[$i] -shl 8);  $i++ }
            if ($op -band 0x04) { $cpOff = $cpOff -bor ([long]$Delta[$i] -shl 16); $i++ }
            if ($op -band 0x08) { $cpOff = $cpOff -bor ([long]$Delta[$i] -shl 24); $i++ }
            if ($op -band 0x10) { $cpSize = $cpSize -bor [long]$Delta[$i]; $i++ }
            if ($op -band 0x20) { $cpSize = $cpSize -bor ([long]$Delta[$i] -shl 8);  $i++ }
            if ($op -band 0x40) { $cpSize = $cpSize -bor ([long]$Delta[$i] -shl 16); $i++ }
            if ($cpSize -eq 0) { $cpSize = 0x10000 }
            $out.Write($Base, [int]$cpOff, [int]$cpSize)
        } elseif ($op -ne 0) {
            $out.Write($Delta, $i, $op); $i += $op
        } else {
            throw 'Invalid delta opcode 0x00.'
        }
    }
    $result = $out.ToArray(); $out.Dispose()
    if ($result.Length -ne [int]$rsize) { throw "Delta result size mismatch: expected $rsize, got $($result.Length)." }
    return $result
}

function Get-PsGitPackObjectAt {
    <# .SYNOPSIS Decode the pack object at a byte offset, resolving ofs/ref deltas. Returns @{Type;Content}. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Pack, [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$IdxPath
    )
    $p = [int]$Offset
    $c = $Pack[$p]; $p++
    $type = ($c -shr 4) -band 7
    $size = [long]($c -band 0x0f)
    $shift = 4
    while ($c -band 0x80) { $c = $Pack[$p]; $p++; $size = $size -bor ([long]($c -band 0x7f) -shl $shift); $shift += 7 }

    if ($type -ge 1 -and $type -le 4) {
        $content = Expand-PsGitZlib -Buffer $Pack -Offset $p -ExpectedSize ([int]$size)
        return [pscustomobject]@{ Type = $script:psGitPackTypeNames[$type]; Content = $content }
    }
    if ($type -eq 6) {                                   # ofs-delta
        $c = $Pack[$p]; $p++
        $baseRel = [long]($c -band 0x7f)
        while ($c -band 0x80) { $c = $Pack[$p]; $p++; $baseRel = (($baseRel + 1) -shl 7) -bor ($c -band 0x7f) }
        $base = Get-PsGitPackObjectAt -Pack $Pack -Offset ($Offset - $baseRel) -RepoPath $RepoPath -IdxPath $IdxPath
        $delta = Expand-PsGitZlib -Buffer $Pack -Offset $p -ExpectedSize ([int]$size)
        return [pscustomobject]@{ Type = $base.Type; Content = (Invoke-PsGitDelta -Base $base.Content -Delta $delta) }
    }
    if ($type -eq 7) {                                   # ref-delta
        $baseId = Get-PsGitHexLower -Bytes $Pack -Offset $p -Count 20
        $p += 20
        $delta = Expand-PsGitZlib -Buffer $Pack -Offset $p -ExpectedSize ([int]$size)
        $baseOff = Find-PsGitPackOffset -IdxPath $IdxPath -Id $baseId
        if ($null -ne $baseOff) {
            $base = Get-PsGitPackObjectAt -Pack $Pack -Offset $baseOff -RepoPath $RepoPath -IdxPath $IdxPath
        } else {
            $base = Read-PsGitLooseObject -RepoPath $RepoPath -Id $baseId
        }
        if (-not $base) { throw "ref-delta base $baseId not found (cross-pack thin packs unsupported)." }
        return [pscustomobject]@{ Type = $base.Type; Content = (Invoke-PsGitDelta -Base $base.Content -Delta $delta) }
    }
    throw "Unknown pack object type $type at offset $Offset."
}

function Get-PsGitPackObject {
    <# .SYNOPSIS Find an object by id across all repo packs; returns @{Type;Content} or $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Id)
    $packDir = Join-Path $RepoPath '.git\objects\pack'
    if (-not (Test-Path -LiteralPath $packDir)) { return $null }
    foreach ($idxPath in [System.IO.Directory]::EnumerateFiles($packDir, '*.idx')) {
        $offset = Find-PsGitPackOffset -IdxPath $idxPath -Id $Id
        if ($null -ne $offset) {
            $packPath = [System.IO.Path]::ChangeExtension($idxPath, '.pack')
            $pack = Get-PsGitFileBytesCached -Path $packPath
            return Get-PsGitPackObjectAt -Pack $pack -Offset $offset -RepoPath $RepoPath -IdxPath $idxPath
        }
    }
    return $null
}
