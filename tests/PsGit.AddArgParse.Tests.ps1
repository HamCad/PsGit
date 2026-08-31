<#
.SYNOPSIS
    Edge cases for the quote-aware CLI argument tokenizer added for Gitea issue #13 ("git add" with
    a space in the filename) that tests/PsGit.Adversarial.Tests.ps1 does not already exercise.
.DESCRIPTION
    The adversarial suite's repro only proves a single quoted, space-containing filename can be
    staged through Invoke-PsGitCommand's string form. This file is scoped to what's left:

      - ConvertTo-PsGitArgTokens itself: plain unquoted tokens still split on whitespace like the
        old `-split '\s+'` behavior (no regression), a quoted token's quotes are stripped, more
        than one quoted token in the same string, quoted and unquoted tokens mixed together, and an
        empty string yields zero tokens (the 'add' case's own "usage" guard already keeps this out
        of Invoke-PsGitCommand's actual add path, but the tokenizer must not throw on it either).
      - End-to-end through Add-PsGitFile via Invoke-PsGitCommand: two separate space-containing
        filenames staged in one `add` call, and a quoted + unquoted filename mixed in one call.
      - End-to-end through the native `git` function wrapper (Public/git.ps1), not just
        Invoke-PsGitCommand's string form - `git.ps1` is the thing that re-quotes
        PowerShell-already-split arguments in the first place, so it's the part of the pipeline
        the adversarial suite's direct Invoke-PsGitCommand call skips over.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitAddArgParseRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'ConvertTo-PsGitArgTokens: quote-aware whitespace tokenizing' {

    It 'splits plain unquoted tokens on whitespace, same as before' {
        InModuleScope PsGit {
            $tokens = @(ConvertTo-PsGitArgTokens -Text 'a.txt b.txt   c.txt')
            $tokens.Count | Should Be 3
            $tokens[0] | Should Be 'a.txt'
            $tokens[1] | Should Be 'b.txt'
            $tokens[2] | Should Be 'c.txt'
        }
    }

    It 'keeps a single double-quoted span as one token with quotes stripped' {
        InModuleScope PsGit {
            $tokens = @(ConvertTo-PsGitArgTokens -Text '"Meeting Notes.docx"')
            $tokens.Count | Should Be 1
            $tokens[0] | Should Be 'Meeting Notes.docx'
        }
    }

    It 'handles two separate quoted tokens in the same string' {
        InModuleScope PsGit {
            $tokens = @(ConvertTo-PsGitArgTokens -Text '"file one.txt" "file two.txt"')
            $tokens.Count | Should Be 2
            $tokens[0] | Should Be 'file one.txt'
            $tokens[1] | Should Be 'file two.txt'
        }
    }

    It 'handles a quoted token mixed with an unquoted token' {
        InModuleScope PsGit {
            $tokens = @(ConvertTo-PsGitArgTokens -Text '"file one.txt" plain.txt')
            $tokens.Count | Should Be 2
            $tokens[0] | Should Be 'file one.txt'
            $tokens[1] | Should Be 'plain.txt'
        }
    }

    It 'returns zero tokens for an empty string' {
        InModuleScope PsGit {
            $tokens = @(ConvertTo-PsGitArgTokens -Text '')
            $tokens.Count | Should Be 0
        }
    }
}

Describe 'Adversarial follow-up: git add handles more than the single-file repro' {

    It 'stages two separate space-containing filenames in one add call' {
        $repo = New-PsGitAddArgParseRepo 'adv-spaces-multi'
        'one' | Set-Content -LiteralPath (Join-Path $repo 'file one.txt') -NoNewline -Encoding UTF8
        'two' | Set-Content -LiteralPath (Join-Path $repo 'file two.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add "file one.txt" "file two.txt"' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 2
        (@($st.Staged | ForEach-Object Path) -contains 'file one.txt') | Should Be $true
        (@($st.Staged | ForEach-Object Path) -contains 'file two.txt') | Should Be $true
    }

    It 'stages a quoted space-containing filename mixed with a plain filename in one add call' {
        $repo = New-PsGitAddArgParseRepo 'adv-spaces-mixed'
        'spaced' | Set-Content -LiteralPath (Join-Path $repo 'Meeting Notes.docx') -NoNewline -Encoding UTF8
        'plain' | Set-Content -LiteralPath (Join-Path $repo 'plain.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add "Meeting Notes.docx" plain.txt' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 2
    }

    It 'stages a space-containing filename through the native `git` function wrapper end-to-end' {
        $repo = New-PsGitAddArgParseRepo 'adv-spaces-gitfn'
        Push-Location $repo
        try {
            'meeting notes' | Set-Content -LiteralPath (Join-Path $repo 'Meeting Notes.docx') -NoNewline -Encoding UTF8
            git add 'Meeting Notes.docx'
            $st = Get-PsGitStatus -RepoPath $repo
            @($st.Staged).Count | Should Be 1
            $st.Staged[0].Path | Should Be 'Meeting Notes.docx'
        } finally {
            Pop-Location
        }
    }
}
