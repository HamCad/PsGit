function Restore-PsGitIndexFile {
    <#
    .SYNOPSIS
        Reset index entries for the given path(s) - or every path, if none given - to match HEAD.
        Never touches the working tree. This is "unstage": the engine behind both `git reset`
        (bare or with pathspecs) and `git restore --staged`.
    .DESCRIPTION
        For each target path: if HEAD's tree has it, the index entry is overwritten to HEAD's
        mode/id (undoes a staged edit or a staged delete); if HEAD does not have it, the index
        entry is dropped instead (undoes a staged `add` of a new file). A path already matching
        HEAD is a no-op. With no -Path at all, every path that appears in either the index or
        HEAD's tree is covered - equivalent to real git's bare `git reset`.
    .PARAMETER Path
        Repo-relative paths to unstage. Omit (or pass an empty array) to unstage everything.
    .NOTES
        PowerShell 5.1+. Exported. See Gitea #32.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [string[]]$Path = @())

    $head = Get-PsGitHead -RepoPath $RepoPath
    $headMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    if ($head.Id) {
        $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $RepoPath -Id $head.Id).Content
        foreach ($e in (Expand-PsGitTree -RepoPath $RepoPath -TreeId $commit.Tree)) { $headMap[$e.Path] = $e }
    }
    $idxMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) { $idxMap[$e.Path] = $e }

    $targets = if ($Path -and $Path.Count -gt 0) {
        @($Path | ForEach-Object {
            $key = ($_ -replace '\\', '/')
            while ($key.StartsWith('./')) { $key = $key.Substring(2) }
            $key
        })
    } else {
        $all = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($k in $idxMap.Keys) { [void]$all.Add($k) }
        foreach ($k in $headMap.Keys) { [void]$all.Add($k) }
        @($all)
    }

    foreach ($key in $targets) {
        Assert-PsGitSafeTreePath -Path $key
        if ($headMap.ContainsKey($key)) {
            $he = $headMap[$key]
            $size = (Get-PsGitObject -RepoPath $RepoPath -Id $he.Id).Content.Length
            $idxMap[$key] = [pscustomobject]@{ Path = $key; Mode = $he.Mode; Id = $he.Id; Size = $size }
        } else {
            [void]$idxMap.Remove($key)
        }
    }
    Write-PsGitIndex -RepoPath $RepoPath -Entries @($idxMap.Values)
}
