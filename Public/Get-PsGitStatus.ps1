function Get-PsGitStatus {
    <# .SYNOPSIS Compare HEAD tree / index / working tree into staged, unstaged, untracked. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $head = Get-PsGitHead -RepoPath $RepoPath
    $branch = if ($head.Symbolic) { $head.Ref -replace '^refs/heads/', '' } else { '(detached)' }
    $headMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    if ($head.Id) {
        $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $RepoPath -Id $head.Id).Content
        foreach ($e in (Expand-PsGitTree -RepoPath $RepoPath -TreeId $commit.Tree)) { $headMap[$e.Path] = $e.Id }
    }
    $idxMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) { $idxMap[$e.Path] = $e.Id }

    $staged = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $idxMap.Keys) {
        if (-not $headMap.ContainsKey($p)) { $staged.Add([pscustomobject]@{ Path = $p; State = 'added' }) }
        elseif ($headMap[$p] -ne $idxMap[$p]) { $staged.Add([pscustomobject]@{ Path = $p; State = 'modified' }) }
    }
    foreach ($p in $headMap.Keys) {
        if (-not $idxMap.ContainsKey($p)) { $staged.Add([pscustomobject]@{ Path = $p; State = 'deleted' }) }
    }

    $work = Get-PsGitWorkingFile -RepoPath $RepoPath
    $unstaged = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $idxMap.Keys) {
        $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $p)
        if (-not (Test-Path -LiteralPath $abs)) { $unstaged.Add([pscustomobject]@{ Path = $p; State = 'deleted' }); continue }
        $bytes = [System.IO.File]::ReadAllBytes($abs)
        if ((Get-PsGitObjectId -Type 'blob' -Content $bytes) -ne $idxMap[$p]) {
            $unstaged.Add([pscustomobject]@{ Path = $p; State = 'modified' })
        }
    }
    $untracked = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $work) { if (-not $idxMap.ContainsKey($p)) { $untracked.Add($p) } }

    return [pscustomobject]@{
        Branch = $branch
        Staged = $staged.ToArray()
        Unstaged = $unstaged.ToArray()
        Untracked = $untracked.ToArray()
    }
}
