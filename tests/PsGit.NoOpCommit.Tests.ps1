<#
.SYNOPSIS
    Edge cases for the no-op-commit guard added for Gitea issue #15 (`commit -m` allowed a
    duplicate empty commit) that tests/PsGit.Adversarial.Tests.ps1 does not already exercise.
.DESCRIPTION
    The adversarial suite's repro only proves the CLI's `commit -m` path refuses a second commit
    when literally nothing changed since the first. This file is scoped to what's left:

      - New-PsGitCommit itself throws when the new tree id equals the parent's tree id - proving
        the guard lives in the engine function (so any caller gets it, not just the CLI's `-m`
        string-parsing path) rather than being duplicated per call site.
      - The initial commit (no parent yet) is never treated as a no-op, even for an empty
        tree/index - there is nothing to compare against yet.
      - A commit that touches the working tree but nets back to the *same* content as HEAD (edit
        then revert, still staged) is still refused - the guard compares actual tree content, not
        "was `git add` called since the last commit."
      - A commit that legitimately produces a different tree (e.g. a genuinely reverted file
        alongside one real change) still succeeds - the guard doesn't over-fire on any staged
        activity, only on a truly identical resulting tree.
      - The interactive (no `-m`) CLI path still shows its existing friendly "Nothing staged"
        message and never reaches Read-Host, rather than surfacing the engine's thrown message -
        a regression check that the two `commit` entry points still behave distinctly for a human
        at the prompt vs. a scripted `-m` call.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitNoOpCommitRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'New-PsGitCommit: refuses a commit whose tree matches its parent' {

    It 'throws when called directly with an unchanged index' {
        $repo = New-PsGitNoOpCommitRepo 'noop-direct'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $null = New-PsGitCommit -RepoPath $repo -Message 'first'

        $threw = $false
        try { New-PsGitCommit -RepoPath $repo -Message 'second, nothing changed' } catch { $threw = $true }
        $threw | Should Be $true
        @(Get-PsGitLog -RepoPath $repo).Count | Should Be 1
    }

    It 'does not treat the very first commit (no parent) as a no-op' {
        $repo = New-PsGitNoOpCommitRepo 'noop-initial'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $threw = $false
        try { $null = New-PsGitCommit -RepoPath $repo -Message 'first' } catch { $threw = $true }
        $threw | Should Be $false
        @(Get-PsGitLog -RepoPath $repo).Count | Should Be 1
    }

    It 'refuses a commit whose staged edit was reverted back to HEAD content' {
        $repo = New-PsGitNoOpCommitRepo 'noop-revert'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $null = New-PsGitCommit -RepoPath $repo -Message 'first'

        'v2' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'

        $threw = $false
        try { New-PsGitCommit -RepoPath $repo -Message 'edit then revert' } catch { $threw = $true }
        $threw | Should Be $true
        @(Get-PsGitLog -RepoPath $repo).Count | Should Be 1
    }

    It 'still allows a commit that produces a genuinely different tree' {
        $repo = New-PsGitNoOpCommitRepo 'noop-realchange'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $null = New-PsGitCommit -RepoPath $repo -Message 'first'

        'v2' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $threw = $false
        try { $null = New-PsGitCommit -RepoPath $repo -Message 'real change' } catch { $threw = $true }
        $threw | Should Be $false
        @(Get-PsGitLog -RepoPath $repo).Count | Should Be 2
    }
}

Describe 'Invoke-PsGitCommand commit: the interactive and -m paths still behave distinctly' {

    It 'the no-message path still shows its own friendly message and never calls Read-Host' {
        $repo = New-PsGitNoOpCommitRepo 'noop-interactive'
        Invoke-PsGitCommand -CommandInput 'init' -RepoPath $repo
        'x' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "first"' -RepoPath $repo

        # Nothing is staged now, and no -m is given: this must hit the existing "Nothing staged"
        # early-return, not fall through to Read-Host (which would hang/throw with no input
        # available under Pester) or to New-PsGitCommit's newly-added throw.
        { Invoke-PsGitCommand -CommandInput 'commit' -RepoPath $repo } | Should Not Throw
        @(Get-PsGitLog -RepoPath $repo).Count | Should Be 1
    }
}
