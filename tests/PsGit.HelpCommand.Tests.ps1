<#
.SYNOPSIS
    Coverage for Gitea #31 (`git help`/`git -h` did nothing useful) and #33 (the native `git`
    wrapper should accept ordinary git-style syntax, dash-prefixed flags included).
.DESCRIPTION
    #31: `Invoke-PsGitCommand`'s switch had no 'help' case at all (fell through to "Unknown
    subcommand"), and even a future 'help' case would have been unreachable outside a repo since
    the not-a-repo gate ran before the switch. Fixed by adding a 'help'/'-h'/'--help' case that
    prints a command list + examples + general usage (Format-PsGitHelpLine), and exempting those
    three tokens from the not-a-repo gate the same way 'init' already was.

    #33: the native `git` function (Public/git.ps1) declared `[Parameter(Position = 0)]$Subcommand`,
    so PowerShell's own parameter binder tried to match any dash-prefixed token (e.g. `-h`,
    `--help`) against a parameter name before the function body ever ran, and threw - `git -h`
    never reached Invoke-PsGitCommand at all. Fixed by reading $args instead of a declared param
    block, which skips PowerShell's binder entirely.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitHelpRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'Issue #31: git help / -h / --help' {

    It 'help lists every wrapper command at the top' {
        $repo = New-PsGitHelpRepo 'help-basic'
        $out = Invoke-PsGitCommand -CommandInput 'help' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Commands:'
        foreach ($token in @('git init', 'git status', 'git add', 'git commit', 'git log', 'git diff', 'git branch', 'git checkout')) {
            $out | Should Match ([regex]::Escape($token))
        }
    }

    It 'help includes an examples section' {
        $repo = New-PsGitHelpRepo 'help-examples'
        $out = Invoke-PsGitCommand -CommandInput 'help' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Examples:'
        $out | Should Match 'git commit -m "initial commit"'
    }

    It '-h and --help both produce the same help text as help' {
        $repo = New-PsGitHelpRepo 'help-aliases'
        $viaHelp = Invoke-PsGitCommand -CommandInput 'help' -RepoPath $repo 6>&1 | Out-String
        $viaDashH = Invoke-PsGitCommand -CommandInput '-h' -RepoPath $repo 6>&1 | Out-String
        $viaDashDashHelp = Invoke-PsGitCommand -CommandInput '--help' -RepoPath $repo 6>&1 | Out-String
        $viaDashH | Should Be $viaHelp
        $viaDashDashHelp | Should Be $viaHelp
    }

    It 'help works even outside an initialized repo' {
        $notARepo = Join-Path $TestDrive 'help-no-repo'
        New-Item -ItemType Directory -Path $notARepo -Force | Out-Null
        $out = Invoke-PsGitCommand -CommandInput 'help' -RepoPath $notARepo 6>&1 | Out-String
        $out | Should Match 'Commands:'
        $out | Should Not Match 'Not a git repository'
    }

    It 'an unknown subcommand now hints at git help' {
        $repo = New-PsGitHelpRepo 'help-hint'
        $out = Invoke-PsGitCommand -CommandInput 'frobnicate' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match "Unknown subcommand 'frobnicate'"
        $out | Should Match 'git help'
    }
}

Describe 'Issue #33: the native git wrapper accepts dash-prefixed flags without throwing' {

    It 'git -h does not throw a parameter-binding error and prints help' {
        $repo = New-PsGitHelpRepo 'wrapper-dash-h'
        Push-Location $repo
        try {
            $out = git -h 6>&1 | Out-String
            $out | Should Match 'Commands:'
        } finally {
            Pop-Location
        }
    }

    It 'git --help does not throw a parameter-binding error and prints help' {
        $repo = New-PsGitHelpRepo 'wrapper-dash-dash-help'
        Push-Location $repo
        try {
            $out = git --help 6>&1 | Out-String
            $out | Should Match 'Commands:'
        } finally {
            Pop-Location
        }
    }

    It 'git help still works via the wrapper too' {
        $repo = New-PsGitHelpRepo 'wrapper-help'
        Push-Location $repo
        try {
            $out = git help 6>&1 | Out-String
            $out | Should Match 'Commands:'
        } finally {
            Pop-Location
        }
    }

    It 'git -h works even outside an initialized repo (no premature parameter-binding error)' {
        $notARepo = Join-Path $TestDrive 'wrapper-dash-h-no-repo'
        New-Item -ItemType Directory -Path $notARepo -Force | Out-Null
        Push-Location $notARepo
        try {
            $out = git -h 6>&1 | Out-String
            $out | Should Match 'Commands:'
            $out | Should Not Match 'Not a git repository'
        } finally {
            Pop-Location
        }
    }

    It 'ordinary dash-flagged git syntax (git commit -m "msg") still round-trips through the wrapper' {
        $repo = New-PsGitHelpRepo 'wrapper-commit-flag'
        Push-Location $repo
        try {
            'hi' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
            git add .
            git commit -m 'first commit'
            $log = @(Get-PsGitLog -RepoPath $repo)
            $log.Count | Should Be 1
            $log[0].Message.Trim() | Should Be 'first commit'
        } finally {
            Pop-Location
        }
    }
}
