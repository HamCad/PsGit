<#
.SYNOPSIS
    Regression test for a git-t-mining candidate (#23 handoff, PROGRESS.md candidate #12):
    Remove-PsGitBranch always reported "not found" for a branch that exists only in
    .git/packed-refs, even though Get-PsGitBranch (same repo) listed it normally.
.DESCRIPTION
    Get-PsGitRef and Get-PsGitBranch resolve a branch via its loose ref file OR .git/packed-refs.
    Remove-PsGitBranch's existence check and delete only ever looked at the loose file
    (Test-Path -LiteralPath $file / Remove-Item -LiteralPath $file), never consulting packed-refs
    at all - so `git branch -d <packed-branch>` always failed with a misleading "not found" for a
    branch the CLI's own `git branch` output just showed. PsGit never writes packed-refs itself,
    but it reads repos that have one (real-git-authored, or the tests/fixtures/crosscompat.zip
    fixture used below, built by real `git pack-refs --all`), so this was reachable without any
    unusual setup - any repo PsGit reads that real git has run 'gc'/'pack-refs' on.

    Fixed by resolving existence via Get-PsGitRef (loose-or-packed) instead of Test-Path on the
    loose file alone, and adding Remove-PsGitPackedRefEntry (Private/PsGitRefs.ps1) to rewrite
    packed-refs dropping the deleted branch's line (and its peeled '^' line, if any) when there's
    no loose file to remove.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force
. (Join-Path $PSScriptRoot 'Fixture.Helpers.ps1')

Describe 'BranchPackedRefs: deleting a branch that exists only in .git/packed-refs' {

    It 'deletes a packed-refs-only branch instead of reporting "not found"' {
        $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
        $repo = $fixture.Path
        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads\history\case-clash')) | Should Be $false

        { Remove-PsGitBranch -RepoPath $repo -Name 'history/case-clash' -Force } | Should Not Throw

        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'history/case-clash' }).Count | Should Be 0
    }

    It 'the deleted branch is actually gone from packed-refs on disk, not just absent from Get-PsGitBranch' {
        $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
        $repo = $fixture.Path

        Remove-PsGitBranch -RepoPath $repo -Name 'history/backslash-path' -Force

        $packed = Get-Content -LiteralPath (Join-Path $repo '.git\packed-refs') -Raw
        $packed | Should Not Match 'refs/heads/history/backslash-path'
    }

    It 'leaves the rest of packed-refs intact - other packed branches still resolve correctly' {
        $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
        $repo = $fixture.Path
        $manifest = $fixture.Manifest
        $survivorSha = ($manifest.branches | Where-Object { $_.name -eq 'history/reserved-names' }).sha

        Remove-PsGitBranch -RepoPath $repo -Name 'history/case-clash' -Force

        $branches = @(Get-PsGitBranch -RepoPath $repo)
        ($branches | Where-Object { $_.Name -eq 'history/reserved-names' }).Id | Should Be $survivorSha
        ($branches | Where-Object { $_.Name -eq 'main' }).IsCurrent | Should Be $true
    }

    It 'still throws "not found" for a name that is genuinely absent from both loose refs and packed-refs' {
        $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
        $repo = $fixture.Path

        { Remove-PsGitBranch -RepoPath $repo -Name 'nosuchbranch' -Force } | Should Throw
    }
}
