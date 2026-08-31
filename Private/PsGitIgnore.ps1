function Convert-PsGitIgnoreGlob {
    <# .SYNOPSIS Translate a gitignore glob (no leading !, no trailing /) to a .NET regex body. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Glob, [switch]$Anchored)
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Glob.Length
    while ($i -lt $n) {
        $c = $Glob[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $n -and $Glob[$i + 1] -eq '*') {
                $i += 2
                if ($i -lt $n -and $Glob[$i] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i++ }
                else { [void]$sb.Append('.*') }
            } else { [void]$sb.Append('[^/]*'); $i++ }
        } elseif ($c -eq '?') { [void]$sb.Append('[^/]'); $i++ }
        elseif ($c -eq '[') {
            [void]$sb.Append('['); $i++
            if ($i -lt $n -and ($Glob[$i] -eq '!' -or $Glob[$i] -eq '^')) { [void]$sb.Append('^'); $i++ }
            if ($i -lt $n -and $Glob[$i] -eq ']') { [void]$sb.Append('\]'); $i++ }
            while ($i -lt $n -and $Glob[$i] -ne ']') {
                if ($Glob[$i] -eq '\') { [void]$sb.Append('\' + $Glob[$i + 1]); $i += 2 }
                else { [void]$sb.Append($Glob[$i]); $i++ }
            }
            [void]$sb.Append(']'); $i++
        } elseif ($c -eq '\') {
            if ($i + 1 -lt $n) { [void]$sb.Append([regex]::Escape([string]$Glob[$i + 1])); $i += 2 } else { $i++ }
        } else { [void]$sb.Append([regex]::Escape([string]$c)); $i++ }
    }
    $body = $sb.ToString()
    $prefix = if ($Anchored) { '^' } else { '^(?:.*/)?' }
    return $prefix + $body + '(?:/.*)?$'
}

function Get-PsGitIgnoreRule {
    <# .SYNOPSIS Load all .gitignore files under RepoPath as ordered rules (shallow dirs first). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $rules = [System.Collections.Generic.List[object]]::new()
    $files = Get-ChildItem -LiteralPath $RepoPath -Recurse -File -Filter '.gitignore' -Force |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        Sort-Object { ($_.DirectoryName.Length) }
    foreach ($f in $files) {
        $base = $f.DirectoryName.Substring($RepoPath.Length).TrimStart('\', '/') -replace '\\', '/'
        foreach ($raw in (Get-Content -LiteralPath $f.FullName)) {
            $line = $raw -replace '\s+$', ''
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $neg = $false
            if ($line.StartsWith('!')) { $neg = $true; $line = $line.Substring(1) }
            elseif ($line.StartsWith('\#') -or $line.StartsWith('\!')) { $line = $line.Substring(1) }
            $dirOnly = $false
            if ($line.EndsWith('/')) { $dirOnly = $true; $line = $line.Substring(0, $line.Length - 1) }
            $anchored = $line.TrimEnd('/').Contains('/')
            if ($line.StartsWith('/')) { $line = $line.Substring(1) }
            $rules.Add([pscustomobject]@{
                Base = $base; Negation = $neg; DirOnly = $dirOnly
                Regex = [regex]::new((Convert-PsGitIgnoreGlob -Glob $line -Anchored:$anchored), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            })
        }
    }
    # Leading comma keeps an empty result an (empty) array; without it PowerShell
    # unwraps it to $null, which downstream Mandatory params reject (throws).
    return , $rules.ToArray()
}

function Get-PsGitIgnoreMatch {
    <# .SYNOPSIS Last-match-wins ignored state for a single path against the rule set.
       Returns $true (ignored), $false (re-included), or $null (no rule matched). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][string]$Rel,
        [switch]$IsDir
    )
    $state = $null
    foreach ($r in $Rules) {
        # rule applies only to paths under its base directory
        if ($r.Base -ne '' -and -not ($Rel -eq $r.Base -or $Rel.StartsWith($r.Base + '/'))) { continue }
        $sub = if ($r.Base -eq '') { $Rel } elseif ($Rel -eq $r.Base) { '' } else { $Rel.Substring($r.Base.Length + 1) }
        if ($r.DirOnly) {
            # A dir-only pattern (trailing '/') matches a path iff it matches a *directory* on that
            # path: the leaf only when IsDir, or any proper ancestor directory (always a directory
            # because something lives under it). Test each directory candidate; the rule's own
            # '(?:/.*)?$' tail lets an ancestor match cover everything beneath it.
            $matched = $false
            $segments = $sub -split '/'
            $ancestorCount = $segments.Count - 1   # proper ancestor directories of the leaf
            $limit = if ($IsDir) { $segments.Count } else { $ancestorCount }
            for ($k = 1; $k -le $limit; $k++) {
                $candidate = ($segments[0..($k - 1)] -join '/')
                if ($r.Regex.IsMatch($candidate)) { $matched = $true; break }
            }
            if ($matched) { $state = -not $r.Negation }
        }
        elseif ($r.Regex.IsMatch($sub)) { $state = -not $r.Negation }
    }
    return $state
}

function Test-PsGitIgnored {
    <# .SYNOPSIS Decide whether RelPath is ignored, matching git's ignore precedence/semantics. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RelPath,
        [switch]$IsDir,
        [AllowEmptyCollection()][object[]]$Rules
    )
    $rel = $RelPath -replace '\\', '/'
    $rules = if ($PSBoundParameters.ContainsKey('Rules')) { $Rules } else { Get-PsGitIgnoreRule -RepoPath $RepoPath }
    # Git never descends into an excluded directory: a path is ignored if any ancestor directory of
    # it is ignored (and not re-included). Evaluate each ancestor directory top-down (shortest
    # prefix first); the first ancestor that resolves to ignored seals the verdict and a deeper '!'
    # cannot rescue the path. Each level uses normal last-match-wins evaluation.
    $segments = $rel -split '/'
    for ($k = 1; $k -lt $segments.Count; $k++) {
        $ancestor = ($segments[0..($k - 1)] -join '/')
        $ancestorState = Get-PsGitIgnoreMatch -Rules $rules -Rel $ancestor -IsDir
        if ($ancestorState -eq $true) { return $true }
    }
    # No ancestor directory excludes us; evaluate the full path with last-match-wins.
    $leafState = Get-PsGitIgnoreMatch -Rules $rules -Rel $rel -IsDir:$IsDir
    return [bool]$leafState
}
