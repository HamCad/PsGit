function Remove-PsGitFile {
    <#
    .SYNOPSIS
        Unstage path(s): drop their entries from the index.
    .DESCRIPTION
        The counterpart to Add-PsGitFile, which cannot help here: it reads the working file to
        hash it, so it throws on a path that has just been deleted. Recording a deletion needs the
        index entry dropped instead, and nothing else in the engine could do that.

        Idempotent - a path that is not staged is silently ignored, so callers do not have to
        distinguish "never tracked" from "already removed". Paths are repo-relative; backslashes are
        normalised to the forward-slash form the index stores, and a leading './' or '.\' is
        stripped the same way Add-PsGitFile/Get-PsGitDiff do - otherwise a tab-completed
        '.\file.txt' would never match the index's plain 'file.txt' entry and silently no-op
        instead of unstaging anything (the #40 leading-dot-slash bug, same root cause here).
    .PARAMETER RepoPath
        Repository working-tree root.
    .PARAMETER Path
        Repo-relative path(s) to unstage.
    .EXAMPLE
        Remove-PsGitFile -RepoPath $repo -Path @('global/old-fact.md')
    .NOTES
        PowerShell 5.1+. Exported.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Index bookkeeping mirroring Add-PsGitFile.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Path
    )
    $drop = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in $Path) {
        $key = ($p -replace '\\', '/')
        while ($key.StartsWith('./')) { $key = $key.Substring(2) }
        [void]$drop.Add($key)
    }
    $kept = @(Read-PsGitIndex -RepoPath $RepoPath | Where-Object { -not $drop.Contains($_.Path) })
    Write-PsGitIndex -RepoPath $RepoPath -Entries $kept
}
