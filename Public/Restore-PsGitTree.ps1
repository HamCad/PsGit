function Restore-PsGitTree {
    <#
    .SYNOPSIS
        Write a commit/tree's blobs into the working tree, remove tracked files the target tree
        no longer has, and rewrite the index to match.
    .DESCRIPTION
        Two-phase by design (see Gitea issues #8, #9, #10):

        Phase 1 (read-only against the working tree) resolves every target path, loads its blob
        content, and - unless -Force is given - refuses the *entire* restore up front if any
        target file either carries an uncommitted edit the restore would silently discard, or is
        currently read-only and can't be safely overwritten. It also diffs the current index
        against the target tree: any tracked path missing from the target is planned for
        deletion, refused the same way if it carries an uncommitted edit. Nothing on disk is
        touched until every entry - written or removed - has cleared this check.

        Phase 1 also handles a path that changes type between commits (a directory becoming a
        blob/symlink, or vice versa - see Gitea #23/git-t-mining): if a write target is currently
        a directory on disk, every tracked file under it is covered by the ordinary removal
        planning above, and phase 1 refuses the whole restore up front if anything left over after
        those removals would be untracked content destroyed to make room (not overridable by
        -Force, which only ever waives checks on tracked content).

        Phase 2 applies the plan, removals before writes so a type-changed path is fully cleared
        before anything tries to occupy it: writes new/changed content, deletes files the target
        tree dropped, and best-effort prunes directories that removal left empty. If any single
        write/delete throws partway through (a lock that only appears at operation time, a race
        against phase 1, a full disk...), every change this call already made is rolled back in
        reverse order - a removed file is recreated with its prior content (its parent directory
        too, if a type-change write later in the same restore removed it), a written file is
        restored to its prior content or deleted if it didn't exist before - so a failure never
        leaves the working tree straddling two commits, or leaking a file that belongs to a
        different one (branch isolation - #10).
    .PARAMETER Force
        Skip the uncommitted-edit and read-only checks; clears the read-only attribute instead of
        refusing when it's set. Mid-restore failures are still rolled back regardless.
    .NOTES
        PowerShell 5.1+. Public.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Id, [switch]$Force)
    $obj = Get-PsGitObject -RepoPath $RepoPath -Id $Id
    $treeId = if ($obj.Type -eq 'commit') { (ConvertFrom-PsGitCommit -Content $obj.Content).Tree }
              elseif ($obj.Type -eq 'tree') { $Id }
              else { throw "Object $Id is a '$($obj.Type)'; expected commit or tree." }
    $entries = Expand-PsGitTree -RepoPath $RepoPath -TreeId $treeId
    $repoRoot = [System.IO.Path]::GetFullPath($RepoPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    $idxMap = @{}
    foreach ($ie in (Read-PsGitIndex -RepoPath $RepoPath)) { $idxMap[$ie.Path] = $ie.Id }
    $targetPaths = [System.Collections.Generic.HashSet[string]]::new([string[]]@($entries | ForEach-Object { $_.Path }))

    # Phase 1a: plan every write and pre-flight it. No target file is modified in this loop.
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        if (Test-PsGitPathReservedDeviceName -Path $e.Path) {
            throw "Refusing to restore '$($e.Path)': a path segment collides with a Windows reserved device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9) and cannot be safely created as a real file."
        }
        if ($e.Mode -eq '160000') {
            throw "Refusing to restore '$($e.Path)': it is a submodule/gitlink entry (mode 160000, commit $($e.Id) in a separate repository's object store) and PsGit does not support submodules."
        }
        $reparseAncestor = Get-PsGitReparsePointAncestor -RepoPath $RepoPath -Path $e.Path
        if ($reparseAncestor) {
            throw "Refusing to restore '$($e.Path)': '$reparseAncestor' is a symlink or junction, not a real directory - writing through it could place tracked content outside the repository. Remove or replace it manually and retry."
        }
        $blob = Get-PsGitObject -RepoPath $RepoPath -Id $e.Id
        $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $e.Path)
        $absFull = [System.IO.Path]::GetFullPath($abs)
        if (-not $absFull.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to restore '$($e.Path)': resolves outside the repository root."
        }

        $existed = Test-Path -LiteralPath $abs
        $priorBytes = $null
        $replacesDirectory = $false
        if ($existed -and (Get-Item -LiteralPath $abs -Force).PSIsContainer) {
            # Type change: this path is a directory in the working tree but a blob/symlink in the
            # target tree. Every tracked file under it is already covered by the phase 1b removal
            # loop below (any idxMap path not in the target tree gets its own dirty-checked Remove
            # plan entry, -Force included); anything left over once those removals apply is
            # untracked content that would otherwise be silently destroyed to make room, so refuse
            # up front - deliberately NOT overridable by -Force, which only ever waives the
            # uncommitted-*tracked*-change checks elsewhere in this function, never genuinely
            # untracked content.
            $leftover = @(@(Get-PsGitDirectoryLeftoverFile -AbsPath $abs -RelPrefix $e.Path) | Where-Object { -not $idxMap.ContainsKey($_) })
            if ($leftover.Count -gt 0) {
                throw "Restore refused: '$($e.Path)' is a directory in the working tree but a file/symlink in the target tree, and '$($leftover[0])' inside it is untracked and would be destroyed to make room. Move or remove it and retry."
            }
            $replacesDirectory = $true
            $existed = $false
        } elseif ($existed) {
            $priorBytes = [System.IO.File]::ReadAllBytes($abs)
            $item = Get-Item -LiteralPath $abs -Force
            $isReadOnly = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReadOnly)
            if (-not $Force) {
                $onDiskId = Get-PsGitObjectId -Type 'blob' -Content $priorBytes
                if ($onDiskId -ne $e.Id) {
                    $knownId = $idxMap[$e.Path]
                    if ($onDiskId -ne $knownId) {
                        throw "Restore refused: '$($e.Path)' has uncommitted changes that would be overwritten. Re-run with -Force to discard them."
                    }
                }
                if ($isReadOnly) {
                    throw "Restore refused: '$($e.Path)' is read-only and cannot be safely overwritten. Clear the read-only attribute (or close whatever holds it) and retry, or re-run with -Force."
                }
            } elseif ($isReadOnly) {
                Set-ItemProperty -LiteralPath $abs -Name IsReadOnly -Value $false
            }
        }
        $plan.Add([pscustomobject]@{
            Op = 'Write'; Path = $e.Path; Mode = $e.Mode; Id = $e.Id
            AbsPath = $abs; Content = $blob.Content; Existed = $existed; PriorBytes = $priorBytes
            ReplacesDirectory = $replacesDirectory
        })
    }

    # Phase 1b: plan removal of tracked paths the target tree no longer has (branch isolation -
    # #10). Same uncommitted-edit guard as a write: a locally modified file that would be
    # deleted is refused, not silently discarded, unless -Force.
    foreach ($path in $idxMap.Keys) {
        if ($targetPaths.Contains($path)) { continue }
        $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $path)
        $absFull = [System.IO.Path]::GetFullPath($abs)
        if (-not $absFull.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $abs)) { continue }

        $reparseAncestor = Get-PsGitReparsePointAncestor -RepoPath $RepoPath -Path $path
        if ($reparseAncestor) {
            throw "Restore refused: '$path' would be removed by this restore, but '$reparseAncestor' is a symlink or junction, not a real directory - deleting through it could destroy unrelated content on the other end. Remove or replace it manually and retry."
        }

        $priorBytes = [System.IO.File]::ReadAllBytes($abs)
        if (-not $Force) {
            $onDiskId = Get-PsGitObjectId -Type 'blob' -Content $priorBytes
            if ($onDiskId -ne $idxMap[$path]) {
                throw "Restore refused: '$path' has uncommitted changes and would be removed by this restore. Re-run with -Force to discard them."
            }
        }
        $plan.Add([pscustomobject]@{
            Op = 'Remove'; Path = $path; Mode = $null; Id = $null
            AbsPath = $abs; Content = $null; Existed = $true; PriorBytes = $priorBytes
        })
    }

    # Phase 2: apply. Removals run before writes so a type-changed path (directory <-> blob/
    # symlink in either direction between the two commits) is fully cleared before anything tries
    # to occupy it - phase 1a already refused up front (above) if that clearing would have to
    # destroy untracked content. Roll back everything this call already did, in reverse order, if
    # any single step fails.
    $written = [System.Collections.Generic.List[object]]::new()
    $orderedPlan = @($plan | Where-Object { $_.Op -eq 'Remove' }) + @($plan | Where-Object { $_.Op -eq 'Write' })
    try {
        foreach ($p in $orderedPlan) {
            if ($p.Op -eq 'Write') {
                if ($p.ReplacesDirectory -and (Test-Path -LiteralPath $p.AbsPath)) {
                    # Every tracked file under this directory was just removed above (removals run
                    # first); anything left is an empty husk (or empty subdirectories) - phase 1a's
                    # leftover-file check already refused the whole restore if that wasn't true.
                    Remove-Item -LiteralPath $p.AbsPath -Recurse -Force
                }
                $dir = Split-Path -Path $p.AbsPath -Parent
                if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllBytes($p.AbsPath, $p.Content)
                # Belt-and-suspenders backstop for #20, mirroring Set-PsGitRef's own backstop for
                # #14: a path that reaches here without being caught by
                # Test-PsGitPathReservedDeviceName above could still make WriteAllBytes silently
                # redirect to a device instead of creating a file - re-verify the write actually
                # landed rather than trusting WriteAllBytes' silent success.
                if (-not (Test-Path -LiteralPath $p.AbsPath -PathType Leaf)) {
                    throw "Restore failed: no file exists at '$($p.AbsPath)' after writing '$($p.Path)' (possible reserved device name or invalid path)."
                }
            } else {
                Remove-Item -LiteralPath $p.AbsPath -Force
            }
            $written.Add($p)
        }
    } catch {
        for ($i = $written.Count - 1; $i -ge 0; $i--) {
            $w = $written[$i]
            try {
                if ($w.Op -eq 'Remove' -or ($w.Op -eq 'Write' -and $w.Existed)) {
                    # Recreate the parent directory if a type-change write later in this same
                    # restore removed it out from under this now-being-undone entry.
                    $wDir = Split-Path -Path $w.AbsPath -Parent
                    if ($wDir -and -not (Test-Path -LiteralPath $wDir)) { New-Item -ItemType Directory -Path $wDir -Force | Out-Null }
                    [System.IO.File]::WriteAllBytes($w.AbsPath, $w.PriorBytes)
                } else {
                    Remove-Item -LiteralPath $w.AbsPath -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        throw
    }

    # Best-effort: prune directories a removal left empty, the way `git checkout` does. Only
    # runs after the full plan has already applied successfully - never part of the rollback.
    foreach ($p in $plan) {
        if ($p.Op -ne 'Remove') { continue }
        $dir = Split-Path -Path $p.AbsPath -Parent
        while ($dir -and $dir.TrimEnd([IO.Path]::DirectorySeparatorChar) -ne $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) -and (Test-Path -LiteralPath $dir)) {
            if (@(Get-ChildItem -LiteralPath $dir -Force).Count -gt 0) { break }
            Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            $dir = Split-Path -Path $dir -Parent
        }
    }

    $indexEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $plan) {
        if ($p.Op -eq 'Write') {
            $indexEntries.Add([pscustomobject]@{ Path = $p.Path; Mode = $p.Mode; Id = $p.Id; Size = $p.Content.Length })
        }
    }
    Write-PsGitIndex -RepoPath $RepoPath -Entries @($indexEntries)
}
