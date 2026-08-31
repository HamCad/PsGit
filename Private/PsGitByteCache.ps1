# Module-scoped cache of immutable git pack/idx file bytes, keyed by full path. Pack/idx content is
# immutable for a given (mtime, length), so a repack invalidates naturally. Reset on /reload.
$script:psGitByteCacheMaxBytes = 256MB
$script:psGitByteCache = @{}

function Get-PsGitFileBytesCached {
    <# .SYNOPSIS Read a file's bytes, caching by full path + LastWriteTimeUtc + length.
       .DESCRIPTION Returns the cached bytes when the path's mtime and length are unchanged; otherwise
       reads from disk and (if at or under the size cap) stores them. Files over the cap are returned
       uncached - identical to a direct read. No error swallowing: IO exceptions propagate.
       .NOTES PowerShell 5.1+. Private. Used by the pack reader/index to avoid re-reading whole packs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $info = [System.IO.FileInfo]::new($Path)
    $mtime = $info.LastWriteTimeUtc.Ticks
    $len = $info.Length
    $hit = $script:psGitByteCache[$Path]
    if ($hit -and $hit.Mtime -eq $mtime -and $hit.Length -eq $len) { return $hit.Bytes }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($len -le $script:psGitByteCacheMaxBytes) {
        $script:psGitByteCache[$Path] = @{ Mtime = $mtime; Length = $len; Bytes = $bytes }
    }
    return $bytes
}

function Clear-PsGitByteCache {
    <# .SYNOPSIS Empty the git byte cache (tests / future repo-switch hook).
       .NOTES PowerShell 5.1+. Private. #>
    [CmdletBinding()]
    param()
    $script:psGitByteCache = @{}
}
