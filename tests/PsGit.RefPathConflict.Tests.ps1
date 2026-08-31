<#
.SYNOPSIS
    Regression test for a git-t-mining candidate (#23 handoff, PROGRESS.md candidate #7): a ref
    "D/F conflict" (one branch name is a path-prefix of another) crashed with a raw, confusing
    .NET exception instead of a clear git-style error.
.DESCRIPTION
    New-PsGitBranch/Set-PsGitRef did no D/F-conflict check at all. Creating a nested branch
    'foo/bar' when a loose ref 'foo' already existed at refs/heads/foo hit Set-PsGitRef's own
    directory-creation step: Test-Path on the parent path 'refs/heads/foo' returned $true (it's a
    file, not a directory, but Test-Path doesn't distinguish), so the mkdir step silently no-opped,
    and the following WriteAllText into 'refs/heads/foo/bar' threw a raw
    MethodInvocationException wrapping "Could not find a part of the path" - confirmed on Creo
    before this fix. The reverse direction (creating 'baz' when nested branch 'baz/qux' already
    exists) already refused safely via New-PsGitBranch's existing Test-Path check, just with a
    misleading "Branch 'baz' already exists" message for a branch that doesn't exist by that exact
    name - also tightened here. Motivated by t2011-checkout-invalid-head.sh's D/F-conflict premise.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitRefConflictRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    New-PsGitCommit -RepoPath $repo -Message 'initial' | Out-Null
    return $repo
}

Describe 'RefPathConflict: creating a branch whose name D/F-conflicts with an existing branch fails cleanly' {

    It 'creating a nested branch under an existing leaf branch throws a clear, named error (not a raw .NET exception)' {
        $repo = New-PsGitRefConflictRepo 'df-nested-under-leaf'
        New-PsGitBranch -RepoPath $repo -Name 'foo'

        try {
            New-PsGitBranch -RepoPath $repo -Name 'foo/bar'
            throw 'expected New-PsGitBranch to throw'
        } catch {
            $_.Exception.GetType().Name | Should Not Be 'MethodInvocationException'
            $_.Exception.Message | Should Match 'foo'
        }
    }

    It 'never creates a stray ref file or leaves the repo in a broken state after the D/F-conflict refusal' {
        $repo = New-PsGitRefConflictRepo 'df-nested-no-partial-write'
        New-PsGitBranch -RepoPath $repo -Name 'foo'

        try { New-PsGitBranch -RepoPath $repo -Name 'foo/bar' } catch {}

        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads\foo')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repo '.git\refs\heads\foo') -PathType Leaf) | Should Be $true
        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'foo/bar' }).Count | Should Be 0
    }

    It 'creating a leaf branch under an existing nested branch throws a clear, accurate error' {
        $repo = New-PsGitRefConflictRepo 'df-leaf-under-nested'
        New-PsGitBranch -RepoPath $repo -Name 'baz/qux'

        try {
            New-PsGitBranch -RepoPath $repo -Name 'baz'
            throw 'expected New-PsGitBranch to throw'
        } catch {
            $_.Exception.Message | Should Match 'baz'
            $_.Exception.Message | Should Not Match 'already exists\.$'
        }
    }

    It 'an unrelated sibling branch is unaffected by another branch''s D/F conflict' {
        $repo = New-PsGitRefConflictRepo 'df-sibling-unaffected'
        New-PsGitBranch -RepoPath $repo -Name 'foo'
        New-PsGitBranch -RepoPath $repo -Name 'sibling'

        try { New-PsGitBranch -RepoPath $repo -Name 'foo/bar' } catch {}

        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'sibling' }).Count | Should Be 1
    }
}
