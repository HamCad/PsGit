function Restore-PsGitWorktreeFile {
    <#
    .SYNOPSIS
        Overwrite the given path(s) in the working tree with their content from the index -
        discarding unstaged edits. The engine behind `git restore <path>` (no --staged).
    .DESCRIPTION
        Unlike Restore-PsGitTree (a whole-tree checkout that refuses by default when it would
        silently discard an uncommitted edit - see #8), discarding the local edit is the entire
        point of this command, so it always overwrites and never prompts or refuses on that
        account - it matches real git's own `git restore` behavior. It still applies the same
        path-safety checks as every other write path in this module (Assert-PsGitSafeTreePath,
        reserved device names - #14/#20, reparse-point ancestors - #24) and never touches a path
        that isn't already tracked in the index (mirrors real git's "did not match any file(s)
        known to git" refusal - restoring is not a way to create new files).

        Two-phase like Restore-PsGitTree: every path is validated and its blob loaded before any
        file on disk is touched, and if a write partway through a multi-path call throws, every
        file this call already wrote is rolled back to its prior bytes (or deleted, if it did not
        exist before) so a partial failure never leaves some paths restored and others not.
    .PARAMETER Path
        Repo-relative paths to restore. Each must already be tracked in the index.
    .NOTES
        PowerShell 5.1+. Exported. See Gitea #32.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string[]]$Path)

    $idxMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) { $idxMap[$e.Path] = $e }
    $repoRoot = [System.IO.Path]::GetFullPath($RepoPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $Path) {
        $key = ($raw -replace '\\', '/')
        while ($key.StartsWith('./')) { $key = $key.Substring(2) }
        Assert-PsGitSafeTreePath -Path $key
        if (-not $idxMap.ContainsKey($key)) {
            throw "pathspec '$raw' did not match any file(s) known to git"
        }
        if (Test-PsGitPathReservedDeviceName -Path $key) {
            throw "Refusing to restore '$key': a path segment collides with a Windows reserved device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9)."
        }
        $reparseAncestor = Get-PsGitReparsePointAncestor -RepoPath $RepoPath -Path $key
        if ($reparseAncestor) {
            throw "Refusing to restore '$key': '$reparseAncestor' is a symlink or junction, not a real directory."
        }
        $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $key)
        $absFull = [System.IO.Path]::GetFullPath($abs)
        if (-not $absFull.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to restore '$key': resolves outside the repository root."
        }
        if ((Test-Path -LiteralPath $abs) -and (Get-Item -LiteralPath $abs -Force).PSIsContainer) {
            throw "Refusing to restore '$key': a directory exists at that path."
        }
        $entry = $idxMap[$key]
        $blob = Get-PsGitObject -RepoPath $RepoPath -Id $entry.Id
        $existed = Test-Path -LiteralPath $abs
        $priorBytes = if ($existed) { [System.IO.File]::ReadAllBytes($abs) } else { $null }
        $plan.Add([pscustomobject]@{ Path = $key; AbsPath = $abs; Content = $blob.Content; Existed = $existed; PriorBytes = $priorBytes })
    }

    $written = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($p in $plan) {
            if ($p.Existed -and (Get-Item -LiteralPath $p.AbsPath -Force).Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                Set-ItemProperty -LiteralPath $p.AbsPath -Name IsReadOnly -Value $false
            }
            $dir = Split-Path -Path $p.AbsPath -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.File]::WriteAllBytes($p.AbsPath, $p.Content)
            $written.Add($p)
        }
    } catch {
        for ($i = $written.Count - 1; $i -ge 0; $i--) {
            $w = $written[$i]
            try {
                if ($w.Existed) { [System.IO.File]::WriteAllBytes($w.AbsPath, $w.PriorBytes) }
                else { Remove-Item -LiteralPath $w.AbsPath -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
        throw
    }
}
