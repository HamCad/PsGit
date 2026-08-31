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
    .NOTES
        PowerShell 5.1+. Public.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [switch]$Force)
    $head = Get-PsGitHead -RepoPath $RepoPath
    if ($head.Symbolic -and $head.Ref -eq "refs/heads/$Name") { throw "Cannot delete the current branch '$Name'." }
    $file = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'refs' (Join-Path 'heads' (ConvertTo-PsGitNativePath $Name))))
    if (-not (Test-Path -LiteralPath $file)) { throw "Branch '$Name' not found." }
    $tipId = Get-PsGitRef -RepoPath $RepoPath -Name "refs/heads/$Name"

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

    Remove-PsGitReflog -RepoPath $RepoPath -RefName "refs/heads/$Name"
    Remove-Item -LiteralPath $file -Force
}
