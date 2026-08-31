<#
.SYNOPSIS
    Regression test for a git-t-mining candidate (#23 handoff, PROGRESS.md candidate #10): checkout
    had no equivalent of real git's "you are leaving N commits behind, not connected to any of your
    branches" warning when switching away from a detached HEAD orphans commits.
.DESCRIPTION
    Invoke-PsGitCommand's 'checkout' case had no logic at all checking whether the outgoing HEAD, if
    detached, stays reachable from some branch after the switch - a commit made while detached and
    never pointed at by a branch becomes silently harder to find (its only trail is the reflog,
    which real git explicitly warns about here to stop users losing work by accident). Real git only
    warns, it doesn't refuse the checkout - this mirrors that rather than blocking. Motivated by
    t2020-checkout-detach.sh: "checkout warns on orphan commits".
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention. Invoke-PsGitCommand writes via Write-Host (the Information stream), so its
    output is captured via `6>&1 | Out-String`, the pattern already used by
    PsGit.CheckoutBranch.Tests.ps1 / PsGit.CheckoutPreserveEdits.Tests.ps1.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitDetachWarningRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'v1'
    Add-PsGitFile -RepoPath $repo -Path 'a.txt'
    New-PsGitCommit -RepoPath $repo -Message 'initial' -Name 'T' -Email 't@x' | Out-Null
    return $repo
}

Describe 'DetachOrphanWarning: switching away from a detached HEAD warns if it orphans commits' {

    It 'warns when checking out a branch leaves a detached, un-branched commit behind' {
        $repo = New-PsGitDetachWarningRepo 'detach-warn-basic'
        $mainId = (Get-PsGitBranch -RepoPath $repo | Where-Object { $_.Name -eq 'main' }).Id

        Invoke-PsGitCommand -CommandInput "checkout $mainId" -RepoPath $repo | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'v2-detached'
        Add-PsGitFile -RepoPath $repo -Path 'a.txt'
        New-PsGitCommit -RepoPath $repo -Message 'detached commit' -Name 'T' -Email 't@x' | Out-Null

        $out = Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'not connected to any branch'
    }

    It 'does NOT warn when the detached commit is still reachable from a branch (e.g. it was branched before switching)' {
        $repo = New-PsGitDetachWarningRepo 'detach-no-warn-branched'
        $mainId = (Get-PsGitBranch -RepoPath $repo | Where-Object { $_.Name -eq 'main' }).Id

        Invoke-PsGitCommand -CommandInput "checkout $mainId" -RepoPath $repo | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'v2-detached'
        Add-PsGitFile -RepoPath $repo -Path 'a.txt'
        New-PsGitCommit -RepoPath $repo -Message 'detached commit' -Name 'T' -Email 't@x' | Out-Null
        New-PsGitBranch -RepoPath $repo -Name 'saved'

        $out = Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo 6>&1 | Out-String
        $out | Should Not Match 'not connected to any branch'
    }

    It 'does NOT warn on an ordinary branch-to-branch switch (never detached at all)' {
        $repo = New-PsGitDetachWarningRepo 'detach-no-warn-normal'
        New-PsGitBranch -RepoPath $repo -Name 'topic'

        $out = Invoke-PsGitCommand -CommandInput 'checkout topic' -RepoPath $repo 6>&1 | Out-String
        $out | Should Not Match 'not connected to any branch'
    }

    It 'still completes the checkout despite the warning - it is informational only, not a refusal' {
        $repo = New-PsGitDetachWarningRepo 'detach-warn-completes'
        $mainId = (Get-PsGitBranch -RepoPath $repo | Where-Object { $_.Name -eq 'main' }).Id

        Invoke-PsGitCommand -CommandInput "checkout $mainId" -RepoPath $repo | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'v2-detached'
        Add-PsGitFile -RepoPath $repo -Path 'a.txt'
        New-PsGitCommit -RepoPath $repo -Message 'detached commit' -Name 'T' -Email 't@x' | Out-Null

        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo | Out-Null

        $current = @(Get-PsGitBranch -RepoPath $repo | Where-Object { $_.IsCurrent })
        $current.Count | Should Be 1
        $current[0].Name | Should Be 'main'
    }
}
