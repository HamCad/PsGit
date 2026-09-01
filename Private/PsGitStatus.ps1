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

function Resolve-PsGitAddPath {
    <#
    .SYNOPSIS
        Expand 'git add' pathspec tokens (a bare file, a directory, or '.') into concrete
        repo-relative targets, matching real git's directory-expansion and delete-staging
        behavior (Gitea #41, #43).
    .DESCRIPTION
        A token that names a directory (or '.') expands to every path under it that actually
        needs staging - untracked, modified, or deleted relative to the index - rather than
        every file that happens to exist on disk today; that's what lets a deleted tracked
        file be picked up even though Get-PsGitWorkingFile can no longer see it on disk. A
        token that names a path exactly (file or directory) is always included even with no
        pending change, matching real git's "naming a path explicitly always attempts it".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string[]]$Token)

    $status = Get-PsGitStatus -RepoPath $RepoPath
    $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $status.Unstaged) { [void]$pending.Add($e.Path) }
    foreach ($p in $status.Untracked) { [void]$pending.Add($p) }

    $result = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($t in $Token) {
        $norm = ($t -replace '\\', '/')
        while ($norm.StartsWith('./')) { $norm = $norm.Substring(2) }
        $norm = $norm.TrimEnd('/')

        if ($norm -eq '' -or $norm -eq '.') {
            foreach ($p in $pending) { if ($seen.Add($p)) { $result.Add($p) } }
            continue
        }
        if ($norm.IndexOfAny([char[]]('*', '?')) -ge 0) {
            # PowerShell does not glob-expand a plain string argument, so a wildcard token
            # (e.g. `git add .\src\*`) still arrives here literal - match it ourselves.
            foreach ($p in (@($pending) -like $norm)) { if ($seen.Add($p)) { $result.Add($p) } }
            continue
        }
        $prefix = "$norm/"
        $underScope = @($pending | Where-Object { $_ -eq $norm -or $_.StartsWith($prefix) })
        if ($underScope.Count -gt 0) {
            foreach ($p in $underScope) { if ($seen.Add($p)) { $result.Add($p) } }
        } elseif (-not (Test-Path -LiteralPath (Join-Path $RepoPath (ConvertTo-PsGitNativePath $norm)) -PathType Container)) {
            # No pending change under this scope, and not an existing clean directory either -
            # still pass the exact token through so an explicit `git add <clean tracked path>`
            # stays a harmless no-op instead of being silently dropped.
            if ($seen.Add($norm)) { $result.Add($norm) }
        }
    }
    return $result.ToArray()
}
