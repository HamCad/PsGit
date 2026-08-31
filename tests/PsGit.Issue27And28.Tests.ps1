<#
.SYNOPSIS
    Coverage for Gitea #27 (`git status --porcelain`) and #28 (`git add .\file` / `./file` should
    not be rejected as an unsafe tree path).
.DESCRIPTION
    #27: adds a machine-readable status format (XY code + path, one line per changed/untracked
    path, sorted) so a custom $PROFILE prompt can parse it without scraping the colored human
    output.
    #28: a tab-completed relative path on Windows is prefixed with '.\', which
    Test-PsGitSafeTreePath already rejects as a '.' path segment (by design, for real '../' and
    embedded '.git' traversal - see PsGit.PathSafety.Tests.ps1). Add-PsGitFile now strips a leading
    './' (after backslash normalization) before the safety check, the same way real git treats
    './file' and 'file' as the same path.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitIssueRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'Issue #28: a leading ./ or .\ on an add path is stripped, not rejected' {

    It 'stages a file passed with a leading ".\" (Windows tab-completion form)' {
        $repo = New-PsGitIssueRepo 'issue28-dotbackslash'
        'hi' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .\firstfile.txt' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 1
        $st.Staged[0].Path | Should Be 'firstfile.txt'
    }

    It 'stages a file passed with a leading "./" (POSIX form)' {
        $repo = New-PsGitIssueRepo 'issue28-dotslash'
        'hi' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add ./firstfile.txt' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 1
        $st.Staged[0].Path | Should Be 'firstfile.txt'
    }

    It 'still rejects a real traversal attempt (../ is not just a leading-dot strip)' {
        $repo = New-PsGitIssueRepo 'issue28-traversal-still-blocked'
        $threw = $false
        try {
            Add-PsGitFile -RepoPath $repo -Path @('../outside.txt')
        } catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}

Describe 'Issue #27: git status --porcelain' {

    It 'prints nothing for a clean repo' {
        $repo = New-PsGitIssueRepo 'issue27-clean'
        $global:PsGitPSStatus = Get-PsGitStatus -RepoPath $repo
        InModuleScope PsGit {
            $lines = @(Format-PsGitStatusPorcelain -Status $global:PsGitPSStatus)
            $lines.Count | Should Be 0
        }
    }

    It 'marks a staged-new file as "A "' {
        $repo = New-PsGitIssueRepo 'issue27-staged-add'
        'hi' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path @('a.txt')
        $global:PsGitPSStatus = Get-PsGitStatus -RepoPath $repo
        InModuleScope PsGit {
            $lines = @(Format-PsGitStatusPorcelain -Status $global:PsGitPSStatus)
            $lines.Count | Should Be 1
            $lines[0] | Should Be 'A  a.txt'
        }
    }

    It 'marks an untracked file as "??"' {
        $repo = New-PsGitIssueRepo 'issue27-untracked'
        'hi' | Set-Content -LiteralPath (Join-Path $repo 'u.txt') -NoNewline -Encoding UTF8
        $global:PsGitPSStatus = Get-PsGitStatus -RepoPath $repo
        InModuleScope PsGit {
            $lines = @(Format-PsGitStatusPorcelain -Status $global:PsGitPSStatus)
            $lines.Count | Should Be 1
            $lines[0] | Should Be '?? u.txt'
        }
    }

    It 'marks a path staged-modified then further modified in the working tree as "MM"' {
        $repo = New-PsGitIssueRepo 'issue27-mm'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'm.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path @('m.txt')
        New-PsGitCommit -RepoPath $repo -Message 'init' -Name 'T' -Email 't@localhost' | Out-Null
        'v2' | Set-Content -LiteralPath (Join-Path $repo 'm.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path @('m.txt')
        'v3' | Set-Content -LiteralPath (Join-Path $repo 'm.txt') -NoNewline -Encoding UTF8
        $global:PsGitPSStatus = Get-PsGitStatus -RepoPath $repo
        InModuleScope PsGit {
            $lines = @(Format-PsGitStatusPorcelain -Status $global:PsGitPSStatus)
            $lines.Count | Should Be 1
            $lines[0] | Should Be 'MM m.txt'
        }
    }

    It 'end-to-end through Invoke-PsGitCommand prints only XY-code lines, no header/blank lines' {
        $repo = New-PsGitIssueRepo 'issue27-e2e'
        'hi' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path @('a.txt')
        $out = Invoke-PsGitCommand -CommandInput 'status --porcelain' -RepoPath $repo 6>&1 | Out-String
        $out.Trim() | Should Be 'A  a.txt'
    }
}
