function Read-PsGitIndex {
    <# .SYNOPSIS Parse the git index (DIRC v2/v3) into @{ Path; Mode; Id; Size; Stage } entries. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $file = Join-Path $RepoPath '.git\index'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $b = [System.IO.File]::ReadAllBytes($file)
    if (-not ($b[0] -eq 0x44 -and $b[1] -eq 0x49 -and $b[2] -eq 0x52 -and $b[3] -eq 0x43)) {
        throw "Not a git index (missing DIRC signature): $file"
    }
    $version = Read-PsGitUInt32BE -Bytes $b -Offset 4
    if ($version -ne 2 -and $version -ne 3) { throw "Unsupported index version $version (only v2/v3)." }
    $count = Read-PsGitUInt32BE -Bytes $b -Offset 8
    $p = 12
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($e = 0; $e -lt $count; $e++) {
        $start = $p
        $mode = Read-PsGitUInt32BE -Bytes $b -Offset ($p + 24)
        $size = Read-PsGitUInt32BE -Bytes $b -Offset ($p + 36)
        $id = Get-PsGitHexLower -Bytes $b -Offset ($p + 40) -Count 20
        $flags = ([int]$b[$p + 60] -shl 8) -bor [int]$b[$p + 61]
        $stage = ($flags -shr 12) -band 3
        $pathStart = $p + 62
        if ($version -ge 3 -and ($flags -band 0x4000)) { $pathStart += 2 }   # extended flags (v3)
        $nul = $pathStart
        while ($nul -lt $b.Length -and $b[$nul] -ne 0) { $nul++ }
        $path = [System.Text.Encoding]::UTF8.GetString($b, $pathStart, $nul - $pathStart)
        $contentLen = $nul - $start
        $p = $start + $contentLen + (8 - ($contentLen % 8))   # 8-byte align (>=1 NUL pad)
        $entries.Add([pscustomobject]@{
            Path = $path; Mode = [System.Convert]::ToString($mode, 8); Id = $id; Size = [int]$size; Stage = $stage
        })
    }
    return $entries.ToArray()
}

function Write-PsGitBE32 {
    <# .SYNOPSIS Write a uint32 as 4 big-endian bytes to a BinaryWriter. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.BinaryWriter]$Writer, [Parameter(Mandatory)][uint32]$Value)
    $Writer.Write([byte](($Value -shr 24) -band 0xFF))
    $Writer.Write([byte](($Value -shr 16) -band 0xFF))
    $Writer.Write([byte](($Value -shr 8) -band 0xFF))
    $Writer.Write([byte]($Value -band 0xFF))
}

function Write-PsGitIndex {
    <# .SYNOPSIS Write a DIRC v2 index from @{ Path; Mode; Id; Size } entries (sorted, aligned, SHA-1 trailer). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [object[]]$Entries = @())
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($en in $Entries) { $sorted.Add($en) }
    $sorted.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Path, $b.Path) })

    $ms = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms)
    try {
        $bw.Write([byte[]]@(0x44, 0x49, 0x52, 0x43))   # 'DIRC'
        Write-PsGitBE32 -Writer $bw -Value 2
        Write-PsGitBE32 -Writer $bw -Value ([uint32]$sorted.Count)
        foreach ($en in $sorted) {
            $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($en.Path)
            Write-PsGitBE32 -Writer $bw -Value 0   # ctime sec
            Write-PsGitBE32 -Writer $bw -Value 0   # ctime nsec
            Write-PsGitBE32 -Writer $bw -Value 0   # mtime sec
            Write-PsGitBE32 -Writer $bw -Value 0   # mtime nsec
            Write-PsGitBE32 -Writer $bw -Value 0   # dev
            Write-PsGitBE32 -Writer $bw -Value 0   # ino
            Write-PsGitBE32 -Writer $bw -Value ([uint32][System.Convert]::ToInt32($en.Mode, 8))   # mode
            Write-PsGitBE32 -Writer $bw -Value 0   # uid
            Write-PsGitBE32 -Writer $bw -Value 0   # gid
            Write-PsGitBE32 -Writer $bw -Value ([uint32]$en.Size)   # size
            $sha = New-Object byte[] 20
            for ($k = 0; $k -lt 20; $k++) { $sha[$k] = [Convert]::ToByte($en.Id.Substring($k * 2, 2), 16) }
            $bw.Write($sha)
            $nameLen = [Math]::Min($pathBytes.Length, 0x0FFF)
            $bw.Write([byte](($nameLen -shr 8) -band 0xFF))
            $bw.Write([byte]($nameLen -band 0xFF))
            $bw.Write($pathBytes)
            $contentLen = 62 + $pathBytes.Length
            $bw.Write((New-Object byte[] (8 - ($contentLen % 8))))   # 8-byte align (>=1 NUL)
        }
        $bw.Flush()
        $body = $ms.ToArray()
    } finally { $bw.Dispose(); $ms.Dispose() }

    $trailer = Get-PsGitSHA1Hash -Bytes $body
    $all = New-Object byte[] ($body.Length + 20)
    [Array]::Copy($body, 0, $all, 0, $body.Length)
    [Array]::Copy($trailer, 0, $all, $body.Length, 20)
    [System.IO.File]::WriteAllBytes((Join-Path $RepoPath '.git\index'), $all)
}
