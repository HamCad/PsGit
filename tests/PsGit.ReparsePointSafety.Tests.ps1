<#
.SYNOPSIS
    Regression tests for Gitea #24: Restore-PsGitTree following a symlink/junction planted where
    a tracked directory ancestor should be, letting a restore write or delete outside its
    intended target.
.DESCRIPTION
    [System.IO.Path]::GetFullPath (used by the existing repo-root containment check) does not
    resolve reparse points, and Windows file APIs (File.ReadAllBytes, Remove-Item,
    File.WriteAllBytes) follow them transparently. Confirmed on Creo before the fix: swapping a
    tracked directory for an NTFS junction (no admin rights required, unlike a real symlink) let
    a forward restore write tracked content through the junction to an arbitrary location outside
    the repo, and let a backward restore delete real content on the far end of a junction that had
    replaced a formerly-tracked directory - genuine data exfiltration/destruction, not just a
    failed assertion. Parallel hazard class to the already-fixed '..'/'.git'-traversal (#6/#7) and
    reserved-device-name (#14/#20) path-safety issues, but the escape happens via a reparse point
    on disk rather than anything expressible in the tree path string itself, so the fix
    (Get-PsGitReparsePointAncestor, Private/PsGitPathSafety.ps1) walks the real filesystem instead
    of only inspecting the path.

    Junctions, not symlinks, are used throughout: creating a symlink requires an elevated/
    Administrator token on stock Windows, so a junction is the realistic unprivileged attack
    surface and is what was actually used to confirm the bug on Creo.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention. Junction creation is Windows-only; this suite (like the rest of the
    project) only ever runs on the Creo Windows target.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitReparseSafetyRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'ReparsePointSafety: restoring backward must not delete through a junction' {

    It 'a tracked directory replaced on disk by a junction is refused, not deleted through' {
        $repo = New-PsGitReparseSafetyRepo 'rp-remove'
        $start = New-PsGitCommit -RepoPath $repo -Message 'start'

        New-Item -ItemType Directory -Path (Join-Path $repo 'dir') -Force | Out-Null
        'tracked-content' | Set-Content -LiteralPath (Join-Path $repo 'dir\f') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'dir/f'
        New-PsGitCommit -RepoPath $repo -Message 'add dir/f' | Out-Null

        # Simulate the attack: move the real directory aside and plant an unprivileged junction
        # named 'dir' pointing at the moved-aside copy, so 'dir/f' on disk now resolves through
        # the junction to 'untracked/f'.
        Move-Item -LiteralPath (Join-Path $repo 'dir') -Destination (Join-Path $repo 'untracked')
        New-Item -ItemType Junction -Path (Join-Path $repo 'dir') -Target (Join-Path $repo 'untracked') | Out-Null

        { Restore-PsGitTree -RepoPath $repo -Id $start -Force } | Should Throw

        (Test-Path -LiteralPath (Join-Path $repo 'untracked\f')) | Should Be $true
        (Get-Content -LiteralPath (Join-Path $repo 'untracked\f') -Raw) | Should Be 'tracked-content'
    }
}

Describe 'ReparsePointSafety: restoring forward must not write through a junction' {

    It 'a junction planted where a tracked directory needs to be created is refused, not written through' {
        $repo = New-PsGitReparseSafetyRepo 'rp-write'
        $start = New-PsGitCommit -RepoPath $repo -Message 'start'

        New-Item -ItemType Directory -Path (Join-Path $repo 'dir') -Force | Out-Null
        'tracked-content' | Set-Content -LiteralPath (Join-Path $repo 'dir\f') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'dir/f'
        $head = New-PsGitCommit -RepoPath $repo -Message 'add dir/f'

        Restore-PsGitTree -RepoPath $repo -Id $start -Force

        $elsewhere = Join-Path $TestDrive 'rp-write-elsewhere'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $repo 'dir') -Target $elsewhere | Out-Null

        { Restore-PsGitTree -RepoPath $repo -Id $head -Force } | Should Throw

        (Test-Path -LiteralPath (Join-Path $elsewhere 'f')) | Should Be $false
    }
}
