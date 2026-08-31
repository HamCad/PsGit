<#
.SYNOPSIS
    Coverage for Gitea #32 ("How to restore a modified file back to the unmodified state?" -
    `git restore`/`git reset`/`git unstage` all reported "Unknown subcommand").
.DESCRIPTION
    Adds three related but distinct operations, matching real git's own split:

    - `git restore <path...> | .`            - overwrite the working tree from the index
      (discard an unstaged edit). New engine: Restore-PsGitWorktreeFile.
    - `git restore --staged <path...> | .`   - overwrite the index from HEAD, working tree
      untouched (undo a `git add`). Alias: `git unstage <path...>`. New engine:
      Restore-PsGitIndexFile (also used by plain `git reset`, below).
    - `git reset [<path...>]`                - same index-from-HEAD operation as `restore
      --staged`, but with no path defaults to *every* path (real git's bare `git reset`).
    - `git reset --hard`                     - resets both index and working tree to HEAD;
      thin wrapper over the existing Restore-PsGitTree -Force (already covered end-to-end by
      PsGit.RestoreSafety.Tests.ps1's "-Force discards an uncommitted local edit" case), so this
      file only covers the dispatcher's own non-interactive paths (no commits yet; a clean tree)
      rather than re-proving Restore-PsGitTree's Force behavior.

    Deliberately not covered: `git reset <commit>` (moving HEAD/branch pointer) - not requested
    by #32 and out of scope for this fix.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention. Interactive prompts (Read-Host) are avoided the same way the rest of the
    suite avoids them (see PsGit.NoOpCommit.Tests.ps1) - by only exercising dispatcher paths that
    can't reach the prompt, rather than mocking it.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitRestoreResetRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    'original' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
    'original' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
    Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
    Invoke-PsGitCommand -CommandInput 'commit -m "initial"' -RepoPath $repo
    return $repo
}

Describe 'Issue #32: git restore discards unstaged edits' {

    It 'restores a single modified tracked file back to its indexed/HEAD content' {
        $repo = New-PsGitRestoreResetRepo 'restore-single'
        'edited' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'restore a.txt' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'original'
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Unstaged).Count | Should Be 0
    }

    It 'restore . restores every unstaged file at once' {
        $repo = New-PsGitRestoreResetRepo 'restore-dot'
        'edited-a' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'edited-b' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'restore .' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'original'
        (Get-Content -LiteralPath (Join-Path $repo 'b.txt') -Raw) | Should Be 'original'
    }

    It 'restoring a path git does not know about throws a pathspec error, not a silent no-op' {
        $repo = New-PsGitRestoreResetRepo 'restore-unknown'
        { Restore-PsGitWorktreeFile -RepoPath $repo -Path @('nope.txt') } | Should Throw
    }

    It 'is a harmless no-op on a file with no unstaged changes' {
        $repo = New-PsGitRestoreResetRepo 'restore-noop'
        { Invoke-PsGitCommand -CommandInput 'restore a.txt' -RepoPath $repo } | Should Not Throw
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'original'
    }
}

Describe 'Issue #32: git restore --staged / git unstage leave the working tree alone' {

    It 'restore --staged reverts a staged edit in the index but keeps the working-tree edit' {
        $repo = New-PsGitRestoreResetRepo 'staged-edit'
        'edited' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add a.txt' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'restore --staged a.txt' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'edited'
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 0
        @($st.Unstaged | Where-Object { $_.Path -eq 'a.txt' }).Count | Should Be 1
    }

    It 'restore --staged undoes a staged new file, leaving it untracked again' {
        $repo = New-PsGitRestoreResetRepo 'staged-new'
        'brand new' | Set-Content -LiteralPath (Join-Path $repo 'c.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add c.txt' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'restore --staged c.txt' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 0
        ($st.Untracked -contains 'c.txt') | Should Be $true
        Test-Path -LiteralPath (Join-Path $repo 'c.txt') | Should Be $true
    }

    It 'git unstage is an alias for restore --staged' {
        $repo = New-PsGitRestoreResetRepo 'unstage-alias'
        'edited' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add a.txt' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'unstage a.txt' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 0
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'edited'
    }

    It 'restore --staged . unstages every staged file at once' {
        $repo = New-PsGitRestoreResetRepo 'staged-dot'
        'edited-a' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'edited-b' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'restore --staged .' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 0
        @($st.Unstaged).Count | Should Be 2
    }

    It 'the native git wrapper round-trips restore --staged end to end (dash flag through $args)' {
        $repo = New-PsGitRestoreResetRepo 'staged-wrapper'
        Push-Location $repo
        try {
            'edited' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
            git add a.txt
            git restore --staged a.txt
            $st = Get-PsGitStatus -RepoPath $repo
            @($st.Staged).Count | Should Be 0
        } finally {
            Pop-Location
        }
    }
}

Describe 'Issue #32: git reset (bare / with paths) unstages without touching the working tree' {

    It 'bare reset unstages every staged path, leaving working-tree edits intact' {
        $repo = New-PsGitRestoreResetRepo 'reset-bare'
        'edited-a' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'edited-b' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'reset' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 0
        @($st.Unstaged).Count | Should Be 2
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'edited-a'
    }

    It 'reset <path> unstages only that path, leaving the other file still staged' {
        $repo = New-PsGitRestoreResetRepo 'reset-path'
        'edited-a' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'edited-b' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'reset a.txt' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged | ForEach-Object Path) | Should Be @('b.txt')
        @($st.Unstaged | ForEach-Object Path) | Should Be @('a.txt')
    }
}

Describe 'Issue #32: git reset --hard (non-interactive dispatcher paths only)' {

    It 'reports nothing to reset when there are no commits yet, rather than throwing' {
        $repo = Join-Path $TestDrive 'reset-hard-unborn'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-PsGitRepo -RepoPath $repo
        $out = Invoke-PsGitCommand -CommandInput 'reset --hard' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Nothing to reset'
    }

    It 'runs without prompting when the working tree is already clean' {
        $repo = New-PsGitRestoreResetRepo 'reset-hard-clean'
        $out = Invoke-PsGitCommand -CommandInput 'reset --hard' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'HEAD is now at'
    }
}
