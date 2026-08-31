function Get-PsGitWorkingFile {
    <# .SYNOPSIS List repo-relative non-ignored working files, pruning ignored directories. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $result = [System.Collections.Generic.List[string]]::new()
    # When the repo carries no .gitignore rules nothing is ignorable, so skip the matcher entirely
    # (it requires at least one rule). With rules present, defer to git's parent-exclusion semantics.
    $rules = Get-PsGitIgnoreRule -RepoPath $RepoPath
    $hasRules = $rules.Count -gt 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push('')   # relative dir, '' = root
    while ($stack.Count -gt 0) {
        $relDir = $stack.Pop()
        $absDir = if ($relDir) { Join-Path $RepoPath (ConvertTo-PsGitNativePath $relDir) } else { $RepoPath }
        foreach ($item in (Get-ChildItem -LiteralPath $absDir -Force)) {
            if ($item.Name -eq '.git') { continue }
            $rel = if ($relDir) { "$relDir/$($item.Name)" } else { $item.Name }
            if ($item.PSIsContainer) {
                if (-not $hasRules -or -not (Test-PsGitIgnored -RepoPath $RepoPath -RelPath $rel -IsDir -Rules $rules)) { $stack.Push($rel) }
            } else {
                if (-not $hasRules -or -not (Test-PsGitIgnored -RepoPath $RepoPath -RelPath $rel -Rules $rules)) { $result.Add($rel) }
            }
        }
    }
    return $result.ToArray()
}
