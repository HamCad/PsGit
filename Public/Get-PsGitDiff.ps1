function Get-PsGitDiff {
    <#
    .SYNOPSIS
        Unified diff of the staged/HEAD blob vs the working file for a path.
    .PARAMETER Cached
        Diff HEAD's blob against the index instead of the working file (`git diff --cached`,
        Gitea #40).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Path, [switch]$Cached)

    # Strip a leading './' or '.\' (what Windows tab-completion inserts) so this matches the
    # index's own repo-relative form the same way Add-PsGitFile's stripping does - without it,
    # `git diff .\file.txt` on a tracked file always misses the index lookup below and silently
    # diffs against nothing instead of the real old content (Gitea #40).
    $rel = $Path -replace '\\', '/'
    while ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }

    $idBytes = $null
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) {
        if ($e.Path -eq $rel) { $idBytes = (Get-PsGitObject -RepoPath $RepoPath -Id $e.Id).Content; break }
    }

    if ($Cached) {
        $head = Get-PsGitHead -RepoPath $RepoPath
        $oldBytes = $null
        if ($head.Id) {
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $RepoPath -Id $head.Id).Content
            foreach ($e in (Expand-PsGitTree -RepoPath $RepoPath -TreeId $commit.Tree)) {
                if ($e.Path -eq $rel) { $oldBytes = (Get-PsGitObject -RepoPath $RepoPath -Id $e.Id).Content; break }
            }
        }
        $newBytes = if ($null -ne $idBytes) { $idBytes } else { [byte[]]@() }
    } else {
        $oldBytes = $idBytes
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
    }

    # $oldBytes/$newBytes truthiness must be "is there content", not PowerShell's array-truthiness
    # coercion (which for a single-element array tests that one element instead of array length) -
    # a tracked file whose entire content is one 0x00 byte would otherwise read as falsy/empty here.
    if (($oldBytes -and $oldBytes.Length -gt 0 -and ([Array]::IndexOf($oldBytes, [byte]0) -ge 0)) -or `
        ($newBytes -and $newBytes.Length -gt 0 -and ([Array]::IndexOf($newBytes, [byte]0) -ge 0))) {
        return 'Binary files differ'
    }
    $oldText = if ($oldBytes -and $oldBytes.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($oldBytes) } else { '' }
    $newText = if ($newBytes -and $newBytes.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($newBytes) } else { '' }
    $oldLines = if ($oldText -eq '') { @() } else { @($oldText -split "`n") }
    $newLines = if ($newText -eq '') { @() } else { @($newText -split "`n") }
    return (Get-PsGitDiffLine -OldLines $oldLines -NewLines $newLines) -join "`n"
}
