function Test-PsGitSafeTreePath {
    <#
    .SYNOPSIS
        Checks whether a '/'-separated tree/index path is safe to stage or write to disk.
    .DESCRIPTION
        Tree and index entry paths are always '/'-separated and repo-relative (see
        ConvertTo-PsGitNativePath). A path is unsafe if it is empty, contains a literal '\'
        (which Windows treats as an extra path separator, letting a single tree entry smuggle
        in more path segments than its '/'-split form shows), is rooted/drive-qualified, or -
        once split on '/' - has any segment that is empty, '.', '..', or a '.git' component
        (matched case-insensitively, plus the NTFS 8.3 short-name alias 'git~1' that also
        resolves to '.git' on Windows).

        This is the same class of check real git applies to tree/index entries (the fix for
        CVE-2017-1000117-style attacks and NTFS-short-name '.git' hiding): without it, a
        crafted or corrupted tree can escape the repo root via '..' or overwrite git's own
        control files via a literal '.git/...' entry.
    .PARAMETER Path
        A relative, '/'-separated path as stored in a tree or index entry.
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure - no filesystem access.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path.Contains('\')) { return $false }
    if ($Path.Contains(':')) { return $false }
    if ($Path.StartsWith('/')) { return $false }

    foreach ($segment in $Path.Split('/')) {
        if ([string]::IsNullOrEmpty($segment)) { return $false }
        if ($segment -eq '.' -or $segment -eq '..') { return $false }
        if ($segment -ieq '.git') { return $false }
        if ($segment -ieq 'git~1') { return $false }
    }
    return $true
}

function Assert-PsGitSafeTreePath {
    <# .SYNOPSIS Throws if $Path fails Test-PsGitSafeTreePath. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Path)

    if (-not (Test-PsGitSafeTreePath -Path $Path)) {
        throw "Unsafe tree path '$Path': must be a repo-relative '/'-separated path with no empty, '.', '..', or '.git' component."
    }
}

function Test-PsGitPathReservedDeviceName {
    <#
    .SYNOPSIS
        Checks whether any '/'-separated segment of a tree path collides with a Windows reserved
        device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9), matched case-insensitively and before
        any extension - see Gitea #20, the tree-path parallel to #14's ref-name check
        (Test-PsGitSafeRefName, Private/PsGitRefSafety.ps1).
    .DESCRIPTION
        Deliberately NOT folded into Test-PsGitSafeTreePath/Assert-PsGitSafeTreePath: that check
        runs on every tree read (Expand-PsGitTree) as well as every write, and a tree committed by
        real git on Linux can legitimately contain a file named 'con' (see
        tests/PsGit.CrossCompat.Tests.ps1's history/reserved-names fixture) - rejecting it there
        would make PsGit unable to even read such a commit. The hazard is specific to writing the
        path to a real Windows filesystem, so this check is applied only where Restore-PsGitTree
        is about to do that.
    .PARAMETER Path
        A relative, '/'-separated tree/index path.
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure - no filesystem access.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    foreach ($segment in $Path.Split('/')) {
        $bare = $segment.Split('.')[0]
        if ($script:PsGitReservedDeviceNames -icontains $bare) { return $true }
    }
    return $false
}

function Get-PsGitDirectoryLeftoverFile {
    <#
    .SYNOPSIS
        Recursively lists every real file under an on-disk directory as repo-relative,
        '/'-separated paths - used by Restore-PsGitTree to detect content it would have to
        destroy to replace a directory with a blob/symlink entry (a type change between commits).
    .DESCRIPTION
        Unlike Get-PsGitWorkingFile (Private/PsGitStatus.ps1), this does not consult .gitignore -
        every real file counts, ignored or not, since a checkout that would have to delete it to
        make room for a type-changed path is exactly the case real git refuses rather than
        silently discarding.
    .PARAMETER AbsPath
        Absolute path of the directory to scan.
    .PARAMETER RelPrefix
        The repo-relative, '/'-separated path AbsPath corresponds to (prefixed onto each result).
    .NOTES
        PowerShell 5.1+. Private (not exported).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$AbsPath, [Parameter(Mandatory)][string]$RelPrefix)

    $result = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ Abs = $AbsPath; Rel = $RelPrefix })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $cur.Abs -Force)) {
            $rel = "$($cur.Rel)/$($item.Name)"
            if ($item.PSIsContainer) {
                $stack.Push([pscustomobject]@{ Abs = $item.FullName; Rel = $rel })
            } else {
                $result.Add($rel)
            }
        }
    }
    return $result.ToArray()
}

function Get-PsGitReparsePointAncestor {
    <#
    .SYNOPSIS
        Returns the first ancestor directory of a repo-relative tree path that exists on disk as
        a reparse point (symlink or NTFS junction), or $null if none of its ancestors are.
    .DESCRIPTION
        Windows file APIs (File.ReadAllBytes, Remove-Item, File.WriteAllBytes, Test-Path) follow
        reparse points transparently. [System.IO.Path]::GetFullPath does NOT resolve them, so the
        repo-root containment check in Restore-PsGitTree only ever sees the syntactic path: if a
        real ancestor directory has been swapped for a symlink or an unprivileged NTFS junction
        (no admin rights needed to create one), a write or delete through that path silently
        follows the reparse point to wherever it actually points, on or off the repo. Confirmed on
        Creo (Gitea #24) in both directions: restoring forward wrote tracked content outside the
        repo through a junction planted at a not-yet-existing path, and restoring backward deleted
        real content on the far end of a junction that had replaced a formerly-tracked directory.

        Only ancestor segments are checked, not the leaf itself - the leaf is the entry
        Restore-PsGitTree is about to create/overwrite/remove directly, not traverse through.
    .PARAMETER RepoPath
        Absolute repo root.
    .PARAMETER Path
        A '/'-separated, repo-relative tree/index path (e.g. 'dir/sub/f').
    .NOTES
        PowerShell 5.1+. Private (not exported).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Path)

    $segments = $Path.Split('/')
    $current = $RepoPath
    for ($i = 0; $i -lt $segments.Length - 1; $i++) {
        $current = Join-Path $current $segments[$i]
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                return $current
            }
        }
    }
    return $null
}
