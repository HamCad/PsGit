<#
.SYNOPSIS
    Coverage for Gitea #30 ("Unstaged files and branch behavior" - checking out a branch always
    force-overwrote the entire working tree, silently discarding an uncommitted edit even when
    switching to a branch whose committed content for that file was identical to the one you were
    already on).
.DESCRIPTION
    Root cause: `Invoke-PsGitCommand`'s 'checkout' case blanket-prompted on ANY dirty state
    (staged/unstaged/untracked, anywhere in the repo) and then always called
    `Restore-PsGitTree -Force`, which blindly rewrites every target-tree path regardless of
    whether that path's content actually differs between the current and target commit. Real
    git's checkout only ever touches a path that actually differs between the two commits' trees -
    a non-conflicting local edit (or even a local deletion) rides along across the switch
    untouched, and only a path that WOULD be overwritten with genuinely different content is
    refused (no interactive prompt in real git either - just an outright error naming the path).

    Fixed in two places:
      - `Restore-PsGitTree` gained an opt-in `-PreserveUnaffectedEdits` switch: a target path
        whose id already matches the current index entry is skipped outright (left exactly as it
        is on disk) instead of being rewritten. Deliberately opt-in, NOT the default - `git reset
        --hard` reuses this same engine to restore to a tree that's normally identical to the
        current index (discarding every uncommitted change back to HEAD is the entire point of a
        hard reset), so it must keep its old unconditional-overwrite behavior via plain -Force.
      - `Invoke-PsGitCommand`'s 'checkout' case dropped the blanket dirty-anywhere prompt entirely
        and now calls `Restore-PsGitTree -PreserveUnaffectedEdits` (plus `-Force:$force` for a new
        `-f`/`--force` flag, mirroring real git's `checkout -f`), letting Restore-PsGitTree's own
        precise per-path conflict check be the sole authority.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention. Interactive prompts are avoided structurally here (the prompt code path
    was deleted, not merely unreached) rather than by mocking Read-Host.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitPreserveEditsRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    'original' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
    Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
    Invoke-PsGitCommand -CommandInput 'commit -m "initial"' -RepoPath $repo
    return $repo
}

Describe 'Issue #30: an unstaged edit survives switching to a branch with identical content' {

    It 'the exact reported repro: edit, branch new, checkout - the edit is still there afterward' {
        $repo = New-PsGitPreserveEditsRepo 'repro-basic'
        'my edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'my edit'
        $st = Get-PsGitStatus -RepoPath $repo
        $st.Branch | Should Be 'mybranch'
        @($st.Unstaged | Where-Object { $_.Path -eq 'firstfile.txt' }).Count | Should Be 1
    }

    It 'switching back to the original branch still carries the same non-conflicting edit' {
        $repo = New-PsGitPreserveEditsRepo 'repro-roundtrip'
        'my edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'my edit'
    }

    It 'a locally deleted tracked file stays deleted after switching to a branch with the same committed content' {
        $repo = New-PsGitPreserveEditsRepo 'repro-delete'
        Remove-Item -LiteralPath (Join-Path $repo 'firstfile.txt') -Force
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        Test-Path -LiteralPath (Join-Path $repo 'firstfile.txt') | Should Be $false
    }

    It 'an unrelated untracked file is never touched and never blocks the switch' {
        $repo = New-PsGitPreserveEditsRepo 'repro-untracked'
        'scratch' | Set-Content -LiteralPath (Join-Path $repo 'scratch.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        { Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo } | Should Not Throw
        (Get-Content -LiteralPath (Join-Path $repo 'scratch.txt') -Raw) | Should Be 'scratch'
    }

    It 'does not prompt (no Read-Host) when the working tree is dirty but nothing actually conflicts' {
        $repo = New-PsGitPreserveEditsRepo 'repro-noprompt'
        'my edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        # If this reached a Read-Host prompt under Pester (no console input available), it would
        # throw/hang rather than complete - reaching the success message proves no prompt fired.
        $out = Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Checked out mybranch'
    }
}

Describe 'Issue #30: a genuine conflict is still refused, not silently discarded or clobbered' {

    It 'refuses (with a message naming the path) when the target branch really did change the edited file' {
        $repo = New-PsGitPreserveEditsRepo 'conflict-refuse'
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        'mybranch content' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "mybranch changes firstfile"' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo
        'my uncommitted edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8

        $out = Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match "firstfile.txt' has uncommitted changes"
        $st = Get-PsGitStatus -RepoPath $repo
        $st.Branch | Should Be 'main'
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'my uncommitted edit'
    }

    It '-f/--force discards a genuine conflict and completes the switch, matching real git checkout -f' {
        $repo = New-PsGitPreserveEditsRepo 'conflict-force'
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        'mybranch content' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "mybranch changes firstfile"' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo
        'my uncommitted edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8

        $out = Invoke-PsGitCommand -CommandInput 'checkout -f mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Checked out mybranch'
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'mybranch content'
        (Get-PsGitStatus -RepoPath $repo).Branch | Should Be 'mybranch'
    }
}

Describe 'Issue #30: git reset --hard is unaffected - it still discards every uncommitted change' {
    <#
    `Invoke-PsGitCommand`'s 'reset --hard' case has its own pre-existing dirty-tree Read-Host
    confirmation (separate from, and untouched by, the checkout prompt this issue removed) that
    the rest of this suite structurally avoids reaching rather than mocking - see
    PsGit.RestoreReset.Tests.ps1's own note on this. So this exercises the underlying engine
    directly, the same way that file's "non-interactive dispatcher paths only" tests do.
    #>

    It 'Restore-PsGitTree without -PreserveUnaffectedEdits keeps its old unconditional-overwrite -Force behavior' {
        $repo = New-PsGitPreserveEditsRepo 'restore-default-unaffected'
        $head = (@(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.Name -eq 'main' }).Id
        'my edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Restore-PsGitTree -RepoPath $repo -Id $head -Force
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'original'
    }
}
