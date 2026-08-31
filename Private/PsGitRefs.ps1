function Get-PsGitRef {
    <# .SYNOPSIS Resolve a full ref name (e.g. refs/heads/main) to an id via loose then packed-refs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name)
    $loose = Join-Path $RepoPath (Join-Path '.git' (ConvertTo-PsGitNativePath $Name))
    if (Test-Path -LiteralPath $loose) {
        return (Get-Content -LiteralPath $loose -Raw).Trim()
    }
    $packed = Join-Path $RepoPath '.git\packed-refs'
    if (Test-Path -LiteralPath $packed) {
        foreach ($line in (Get-Content -LiteralPath $packed)) {
            if ($line.StartsWith('#') -or $line.StartsWith('^') -or -not $line.Trim()) { continue }
            $sp = $line.IndexOf(' ')
            if ($sp -lt 0) { continue }
            if ($line.Substring($sp + 1).Trim() -eq $Name) { return $line.Substring(0, $sp) }
        }
    }
    return $null
}

function Remove-PsGitEmptyAncestorDirectory {
    <#
    .SYNOPSIS
        Best-effort prune of now-empty ancestor directories of $LeafPath, walking upward and
        stopping at (never removing) $StopAt itself. Mirrors Restore-PsGitTree's own empty-
        directory pruning after a removal (#10), generalized for ref-tree paths (refs/heads/,
        logs/refs/heads/) instead of the working tree.
    .NOTES
        PowerShell 5.1+. Private (not exported).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LeafPath, [Parameter(Mandatory)][string]$StopAt)
    $stop = $StopAt.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $dir = Split-Path -Path $LeafPath -Parent
    while ($dir -and $dir.TrimEnd([IO.Path]::DirectorySeparatorChar) -ne $stop -and (Test-Path -LiteralPath $dir)) {
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -gt 0) { break }
        Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        $dir = Split-Path -Path $dir -Parent
    }
}

function Remove-PsGitPackedRefEntry {
    <# .SYNOPSIS Rewrite .git/packed-refs dropping the line for $Name (and its peeled '^' line, if any), if present. No-op if $Name isn't packed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name)
    $packed = Join-Path $RepoPath '.git\packed-refs'
    if (-not (Test-Path -LiteralPath $packed)) { return }
    $lines = @(Get-Content -LiteralPath $packed)
    $out = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $isRefLine = -not ($line.StartsWith('#')) -and $line.Trim() -and -not $line.StartsWith('^')
        if ($isRefLine) {
            $sp = $line.IndexOf(' ')
            if ($sp -ge 0 -and $line.Substring($sp + 1).Trim() -eq $Name) {
                $i++
                if ($i -lt $lines.Count -and $lines[$i].StartsWith('^')) { $i++ }
                continue
            }
        }
        $out.Add($line)
        $i++
    }
    [System.IO.File]::WriteAllText($packed, (($out -join "`n") + "`n"))
}

function Get-PsGitHead {
    <# .SYNOPSIS Read HEAD; returns @{ Symbolic; Ref; Id } (Id null for an unborn branch). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $headFile = Join-Path $RepoPath '.git\HEAD'
    if (-not (Test-Path -LiteralPath $headFile)) {
        return [pscustomobject]@{ Symbolic = $false; Ref = $null; Id = $null }
    }
    $head = (Get-Content -LiteralPath $headFile -Raw).Trim()
    if ($head.StartsWith('ref: ')) {
        $ref = $head.Substring(5).Trim()
        return [pscustomobject]@{ Symbolic = $true; Ref = $ref; Id = (Get-PsGitRef -RepoPath $RepoPath -Name $ref) }
    }
    return [pscustomobject]@{ Symbolic = $false; Ref = $null; Id = $head }
}

function Assert-PsGitNoRefPathConflict {
    <#
    .SYNOPSIS
        Throws a clear, git-style error if any ancestor path component of a ref file already
        exists as a plain file rather than a directory - the classic ref "D/F conflict" (e.g.
        creating 'foo/bar' when loose ref 'foo' already exists at refs/heads/foo).
    .DESCRIPTION
        Without this check, Set-PsGitRef's own directory-creation step silently no-ops (Test-Path
        on an ancestor that's actually a file still returns $true, so it looks like the directory
        "already exists") and the subsequent WriteAllText throws a raw, confusing
        MethodInvocationException / DirectoryNotFoundException ("Could not find a part of the
        path") instead of a message naming the actual conflicting ref - found via git-t-mining
        candidate #7 (Gitea #23 handoff), parallel to t2011-checkout-invalid-head.sh's D/F-conflict
        premise.
    .NOTES
        PowerShell 5.1+. Private (not exported).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$FilePath)
    $gitRoot = Join-Path $RepoPath '.git'
    $walk = Split-Path -Path $FilePath -Parent
    while ($walk -and $walk.Length -gt $gitRoot.Length) {
        if ((Test-Path -LiteralPath $walk) -and -not (Test-Path -LiteralPath $walk -PathType Container)) {
            $conflictRef = ($walk.Substring($gitRoot.Length).TrimStart('\', '/') -replace '\\', '/')
            throw "Cannot lock ref '$Name': '$conflictRef' exists; cannot create '$Name'."
        }
        $walk = Split-Path -Path $walk -Parent
    }
}

function Set-PsGitRef {
    <# .SYNOPSIS Write a loose ref file (e.g. refs/heads/main) with an id. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Id)
    $file = Join-Path $RepoPath (Join-Path '.git' (ConvertTo-PsGitNativePath $Name))
    Assert-PsGitNoRefPathConflict -RepoPath $RepoPath -Name $Name -FilePath $file
    $dir = Split-Path -Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($file, "$Id`n")
    # Belt-and-suspenders backstop for #14: a ref name that reaches here without going through
    # Assert-PsGitSafeRefName (e.g. a reserved Windows device name like 'con') can make
    # WriteAllText silently redirect to the device instead of creating a file - re-verify the
    # write actually landed rather than trusting WriteAllText's silent success.
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Failed to write ref '$Name': no file exists at '$file' after writing (possible reserved device name or invalid path)."
    }
}
