<#
.SYNOPSIS
    Regression test for a git-t-mining candidate (#23 handoff, PROGRESS.md candidate #14):
    Get-PsGitDiff silently read through an on-disk reparse point (symlink or unprivileged NTFS
    junction) substituted for a tracked file, diffing the link target's arbitrary content against
    the git blob instead of representing the link itself.
.DESCRIPTION
    [System.IO.File]::ReadAllBytes transparently follows a reparse point on Windows - the same
    on-disk construct Restore-PsGitTree already had to guard against for Gitea #24
    (Get-PsGitReparsePointAncestor), but that guard only covers Restore-PsGitTree's write/removal
    paths, never Get-PsGitDiff.

    Junctions, not symlinks, are used throughout: creating a real symlink requires an elevated/
    Administrator token on stock Windows, so a junction is the realistic unprivileged attack
    surface, matching how #24 was confirmed. This changes the confirmed failure mode from the
    originally-suspected one: since an NTFS junction can only target a directory (never a single
    file), replacing a tracked file with a junction made ReadAllBytes throw a raw
    UnauthorizedAccessException (the OS sees a directory where a file was expected) rather than
    silently leaking the target's content - confirmed on Creo against the pre-fix code before this
    test was written. A real symlink (out of scope for this project's admin-restricted target
    environment, but a genuine gap if that ever changes) CAN target a single file, and would hit
    the silent-content-leak failure mode instead - the fix below handles both.

    Fixed by detecting the ReparsePoint attribute before reading the working-tree side, and
    diffing the link's own .Target text (matching real git's symlink-diff semantics - a symlink's
    tracked "content" is the target path string) instead of either failure mode.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention. Junction creation is Windows-only; this suite (like the rest of the
    project) only ever runs on the Creo Windows target.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitDiffReparseRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'DiffReparsePoint: diffing a tracked file replaced on disk by a junction' {

    It 'does not diff the junction target''s arbitrary content against the git blob' {
        $repo = New-PsGitDiffReparseRepo 'diff-rp-noleak'
        'tracked-content' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        New-PsGitCommit -RepoPath $repo -Message 'add f.txt' | Out-Null

        $elsewhere = Join-Path $TestDrive 'diff-rp-noleak-elsewhere'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        'secret-elsewhere-content' | Set-Content -LiteralPath (Join-Path $elsewhere 'target.txt') -NoNewline -Encoding UTF8

        Remove-Item -LiteralPath (Join-Path $repo 'f.txt') -Force
        New-Item -ItemType Junction -Path (Join-Path $repo 'f.txt') -Target $elsewhere | Out-Null

        $diff = Get-PsGitDiff -RepoPath $repo -Path 'f.txt'
        $diff | Should Not Match 'secret-elsewhere-content'
    }

    It 'represents the junction by its own target path text, not by following it' {
        $repo = New-PsGitDiffReparseRepo 'diff-rp-showtarget'
        'tracked-content' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        New-PsGitCommit -RepoPath $repo -Message 'add f.txt' | Out-Null

        $elsewhere = Join-Path $TestDrive 'diff-rp-showtarget-elsewhere'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null

        Remove-Item -LiteralPath (Join-Path $repo 'f.txt') -Force
        New-Item -ItemType Junction -Path (Join-Path $repo 'f.txt') -Target $elsewhere | Out-Null

        $diff = Get-PsGitDiff -RepoPath $repo -Path 'f.txt'
        $diff | Should Match ([regex]::Escape($elsewhere))
    }

    It 'an ordinary (non-reparse-point) file still diffs its real content normally' {
        $repo = New-PsGitDiffReparseRepo 'diff-rp-normal-unaffected'
        'line1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        New-PsGitCommit -RepoPath $repo -Message 'add f.txt' | Out-Null

        'line1-edited' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        $diff = Get-PsGitDiff -RepoPath $repo -Path 'f.txt'

        $diff | Should Match 'line1-edited'
    }
}
