function Remove-PsGitBranch {
    <#
    .SYNOPSIS
        Delete a local branch ref. Refuses the current branch, and refuses a branch whose tip
        isn't reachable from any other ref unless -Force is given.
    .DESCRIPTION
        Mirrors real git's 'branch -d' (refuses an unmerged branch, "not fully merged") vs.
        'branch -D' (-Force here): without -Force, the branch's tip commit must be an ancestor
        of some other branch's tip (or of a detached HEAD) or the delete is refused, since
        PsGit's only recovery path for an unreachable commit is the reflog (see #11) - once no
        ref points at it and its reflog is gone, it's only recoverable by scanning
        .git/objects by hand.

        Resolves the branch via loose ref file or .git/packed-refs (Get-PsGitRef already checks
        both - see Get-PsGitBranch), not just the loose file, so a branch packed by real git (any
        repo PsGit reads that real git has run 'gc'/'pack-refs' on) can actually be deleted instead
        of always reporting "not found" for a branch 'git branch' itself just listed.
    .NOTES
        PowerShell 5.1+. Public.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [switch]$Force)
    $head = Get-PsGitHead -RepoPath $RepoPath
    if ($head.Symbolic -and $head.Ref -eq "refs/heads/$Name") { throw "Cannot delete the current branch '$Name'." }
    $file = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'refs' (Join-Path 'heads' (ConvertTo-PsGitNativePath $Name))))
    $looseExists = Test-Path -LiteralPath $file
    $tipId = Get-PsGitRef -RepoPath $RepoPath -Name "refs/heads/$Name"
    if (-not $looseExists -and -not $tipId) { throw "Branch '$Name' not found." }

    if (-not $Force) {
        $others = [System.Collections.Generic.List[string]]::new()
        foreach ($b in (Get-PsGitBranch -RepoPath $RepoPath)) {
            if ($b.Name -ne $Name -and $b.Id) { $others.Add($b.Id) }
        }
        if (-not $head.Symbolic -and $head.Id) { $others.Add($head.Id) }

        $merged = $false
        foreach ($otherId in $others) {
            if (Test-PsGitIsAncestor -RepoPath $RepoPath -AncestorId $tipId -DescendantId $otherId) { $merged = $true; break }
        }
        if (-not $merged) {
            throw "Branch '$Name' is not fully merged (tip $tipId is not reachable from any other ref). Re-run with -Force to delete anyway."
        }
    }

    $reflogFile = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'logs' (Join-Path 'refs' (Join-Path 'heads' (ConvertTo-PsGitNativePath $Name)))))
    Remove-PsGitReflog -RepoPath $RepoPath -RefName "refs/heads/$Name"
    # Best-effort: prune now-empty logs/refs/heads/ subdirectories a nested branch (e.g. 'd/e/f')
    # left behind - same hazard as the refs/heads/ case below, but for the reflog tree: without
    # this, a later New-PsGitBranch for a name colliding with the leftover directory (e.g. 'd')
    # throws a raw "Access to the path ... is denied" from Add-PsGitReflogEntry trying to
    # AppendAllText a path that's actually still a directory.
    Remove-PsGitEmptyAncestorDirectory -LeafPath $reflogFile -StopAt (Join-Path $RepoPath (Join-Path '.git' (Join-Path 'logs' (Join-Path 'refs' 'heads'))))

    if ($looseExists) {
        Remove-Item -LiteralPath $file -Force

        # Best-effort: prune now-empty refs/heads/ subdirectories a nested branch (e.g. 'd/e/f')
        # left behind, the same way Restore-PsGitTree prunes empty working-tree directories after
        # a removal (#10) - Test-Path returns $true for a leftover directory too, so without this
        # a later New-PsGitBranch for a name that collides with the stale directory path (e.g.
        # 'd') would wrongly report "already exists" for a branch that doesn't. Bounded to
        # refs/heads/ itself, never walking above it.
        Remove-PsGitEmptyAncestorDirectory -LeafPath $file -StopAt (Join-Path $RepoPath (Join-Path '.git' (Join-Path 'refs' 'heads')))
    }

    # PsGit never writes packed-refs itself, but it reads repos that have one (real-git-authored,
    # or the crosscompat fixtures) - drop the entry there too so a packed-only branch actually
    # disappears, and so a loose+packed leftover (stale packed copy of a branch that also has a
    # loose ref) doesn't resurrect the old id after the loose file above is gone.
    Remove-PsGitPackedRefEntry -RepoPath $RepoPath -Name "refs/heads/$Name"
}
