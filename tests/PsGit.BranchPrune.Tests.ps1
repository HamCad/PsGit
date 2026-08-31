<#
.SYNOPSIS
    Regression test for a git-t-mining candidate (#23 handoff, PROGRESS.md candidate #13): deleting
    a nested branch left stale empty refs/heads/ directories, and a later branch create colliding
    with that leftover directory path wrongly reported "already exists" for a branch that doesn't.
.DESCRIPTION
    Remove-PsGitBranch removed only the leaf ref file (Remove-Item -LiteralPath $file), never
    pruning now-empty parent directories under refs/heads/ - contrast Restore-PsGitTree's
    tree-checkout path, which does prune empty working-tree directories after a removal (#10).
    New-PsGitBranch's existence check is Test-Path -LiteralPath $file, and Test-Path returns $true
    for a directory at that path too, so New-PsGitBranch 'd' right after deleting 'd/e/f' threw
    "Branch 'd' already exists." even though no branch named 'd' existed - a real, reproducible
    "works after deleted" regression vs. real git (t3200-branch.sh: "git branch j/k should work
    after branch j has been deleted"). Fixed by pruning empty refs/heads/ subdirectories after a
    successful delete, bounded to refs/heads/ itself.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitBranchPruneRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    New-PsGitCommit -RepoPath $repo -Message 'initial' | Out-Null
    return $repo
}

Describe 'BranchPrune: deleting a nested branch prunes stale empty refs/heads/ directories' {

    It 'a plain branch name colliding with a deleted nested branch''s directory can be created afterward' {
        $repo = New-PsGitBranchPruneRepo 'prune-collide'
        New-PsGitBranch -RepoPath $repo -Name 'd/e/f'
        Remove-PsGitBranch -RepoPath $repo -Name 'd/e/f' -Force

        { New-PsGitBranch -RepoPath $repo -Name 'd' } | Should Not Throw

        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'd' }).Count | Should Be 1
    }

    It 'leaves no empty directories under refs/heads/ after deleting a nested branch' {
        $repo = New-PsGitBranchPruneRepo 'prune-empty-dirs'
        New-PsGitBranch -RepoPath $repo -Name 'd/e/f'
        Remove-PsGitBranch -RepoPath $repo -Name 'd/e/f' -Force

        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads\d\e')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads\d')) | Should Be $false
    }

    It 'never removes refs/heads/ itself, even for a top-level single-segment branch name' {
        $repo = New-PsGitBranchPruneRepo 'prune-top-level'
        New-PsGitBranch -RepoPath $repo -Name 'topic'
        Remove-PsGitBranch -RepoPath $repo -Name 'topic' -Force

        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads')) | Should Be $true
    }

    It 'a sibling nested branch under the same parent directory survives the sibling''s deletion' {
        $repo = New-PsGitBranchPruneRepo 'prune-sibling'
        New-PsGitBranch -RepoPath $repo -Name 'd/e/f'
        New-PsGitBranch -RepoPath $repo -Name 'd/e/g'
        Remove-PsGitBranch -RepoPath $repo -Name 'd/e/f' -Force

        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads\d\e\g')) | Should Be $true
        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'd/e/g' }).Count | Should Be 1
    }
}
