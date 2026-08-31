<#
.SYNOPSIS
    Coverage for Gitea #29 ("Git Branch create and switch" - `git checkout -b <name>` reported
    "Unknown ref '-b'", and `git branch <name>` alone (no `new`) reported a usage error).
.DESCRIPTION
    Real git's `git checkout -b <name> [<start-point>]` creates a branch (from HEAD, or
    <start-point> if given) and switches to it in one step. `Invoke-PsGitCommand`'s 'checkout'
    case took its first token as a ref name unconditionally, so `-b` was resolved as a ref and
    failed like any other unknown ref. Fixed by special-casing a leading '-b' token: create the
    branch via the existing New-PsGitBranch (which already throws on a name collision, matching
    real git's refusal to clobber an existing branch), then fall through to the same
    checkout-by-name logic used for a plain `git checkout <branch>`.

    Deliberately not covered/changed: bare `git branch <name>` (no `new`) as an alternate way to
    create a branch - the issue's own repro shows the reporter settling on `-b` as the desired
    fix, and `git branch new <name>` already exists as a working spelling.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitCheckoutBranchRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    'original' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
    Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
    Invoke-PsGitCommand -CommandInput 'commit -m "initial"' -RepoPath $repo
    return $repo
}

Describe 'Issue #29: git checkout -b creates and switches to a new branch' {

    It 'creates the branch and switches HEAD to it' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-basic'
        $out = Invoke-PsGitCommand -CommandInput 'checkout -b mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Checked out mybranch'
        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'mybranch' }).Count | Should Be 1
        ($branches | Where-Object { $_.IsCurrent }).Name | Should Be 'mybranch'
    }

    It 'the new branch points at the same commit as the branch it was cut from' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-sameid'
        $before = (@(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.Name -eq 'main' }).Id
        Invoke-PsGitCommand -CommandInput 'checkout -b mybranch' -RepoPath $repo
        $after = (@(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.Name -eq 'mybranch' }).Id
        $after | Should Be $before
    }

    It 'leaves the working tree and index untouched (new branch shares HEAD tree)' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-clean'
        Invoke-PsGitCommand -CommandInput 'checkout -b mybranch' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'original'
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 0
        @($st.Unstaged).Count | Should Be 0
    }

    It 'refuses to clobber a branch name that already exists' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-collide'
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        $out = Invoke-PsGitCommand -CommandInput 'checkout -b mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'already exists'
        $current = @(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.IsCurrent }
        $current.Name | Should Be 'main'
    }

    It 'accepts an explicit start-point branch to cut the new branch from' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-startpoint'
        Invoke-PsGitCommand -CommandInput 'branch new other' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout other' -RepoPath $repo
        'second' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "second"' -RepoPath $repo
        $otherHead = (@(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.Name -eq 'other' }).Id
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout -b fromother other' -RepoPath $repo
        $fromOtherId = (@(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.Name -eq 'fromother' }).Id
        $fromOtherId | Should Be $otherHead
    }

    It 'reports an unknown start-point rather than creating the branch' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-badstart'
        $out = Invoke-PsGitCommand -CommandInput 'checkout -b mybranch nosuchref' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match "Unknown ref 'nosuchref'"
        $branches = @(Get-PsGitBranch -RepoPath $repo)
        @($branches | Where-Object { $_.Name -eq 'mybranch' }).Count | Should Be 0
    }

    It 'writes both a branch-creation and a checkout reflog entry' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-reflog'
        Invoke-PsGitCommand -CommandInput 'checkout -b mybranch' -RepoPath $repo
        $branchReflog = Get-Content -LiteralPath (Join-Path $repo '.git\logs\refs\heads\mybranch') -Raw
        $branchReflog | Should Match 'branch: Created from'
        $headReflog = Get-Content -LiteralPath (Join-Path $repo '.git\logs\HEAD') -Raw
        $headReflog | Should Match 'checkout: moving from main to mybranch'
    }

    It 'the native git wrapper round-trips checkout -b end to end (dash flag through $args)' {
        $repo = New-PsGitCheckoutBranchRepo 'checkout-b-wrapper'
        Push-Location $repo
        try {
            git checkout -b mybranch
            $branches = @(Get-PsGitBranch -RepoPath $repo)
            ($branches | Where-Object { $_.IsCurrent }).Name | Should Be 'mybranch'
        } finally {
            Pop-Location
        }
    }
}
