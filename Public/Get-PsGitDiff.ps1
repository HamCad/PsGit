function Get-PsGitDiff {
    <# .SYNOPSIS Unified diff of the staged/HEAD blob vs the working file for a path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Path)
    $rel = $Path -replace '\\', '/'
    $oldBytes = $null
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) {
        if ($e.Path -eq $rel) { $oldBytes = (Get-PsGitObject -RepoPath $RepoPath -Id $e.Id).Content; break }
    }
    $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $rel)
    $newBytes = if (Test-Path -LiteralPath $abs) {
        $item = Get-Item -LiteralPath $abs -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            # ReadAllBytes transparently follows a reparse point on Windows. For a real symlink
            # (admin-only to create) that means silently diffing whatever arbitrary file the link
            # points at - on or off the repo - as if it were the tracked path's own content. For
            # an unprivileged NTFS junction (which can only target a directory, not a single file)
            # ReadAllBytes instead throws a raw UnauthorizedAccessException, since the OS sees a
            # directory where a file was expected - no content leak, but an ugly crash instead of
            # a sensible diff. Represent the link's own target text instead of either behavior,
            # matching real git's symlink-diff semantics (a symlink's tracked "content" is the
            # target path string, not the bytes - or directory - at the far end of it).
            [System.Text.Encoding]::UTF8.GetBytes(($item.Target -join "`n"))
        } else {
            [System.IO.File]::ReadAllBytes($abs)
        }
    } else { [byte[]]@() }
    if (($oldBytes -and ([Array]::IndexOf($oldBytes, [byte]0) -ge 0)) -or `
        ($newBytes -and ([Array]::IndexOf($newBytes, [byte]0) -ge 0))) {
        return 'Binary files differ'
    }
    $oldText = if ($oldBytes) { [System.Text.Encoding]::UTF8.GetString($oldBytes) } else { '' }
    $newText = if ($newBytes) { [System.Text.Encoding]::UTF8.GetString($newBytes) } else { '' }
    $oldLines = if ($oldText -eq '') { @() } else { $oldText -split "`n" }
    $newLines = if ($newText -eq '') { @() } else { $newText -split "`n" }
    return (Get-PsGitDiffLine -OldLines $oldLines -NewLines $newLines) -join "`n"
}
