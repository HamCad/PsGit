<#
.SYNOPSIS
    Coverage for Gitea #34 ("git checkout can silently discard staged (git add'ed) but
    uncommitted changes") - found while verifying #30's fix.
.DESCRIPTION
    Root cause: `Restore-PsGitTree`'s conflict/no-op check only ever compared two trees (the
    target tree and the current index), using the index as a stand-in for "what was previously
    committed". That's a correct proxy for an ordinary UNSTAGED edit (index == old committed
    content, on-disk differs = the edit) but breaks for a STAGED edit: the index itself already
    holds the staged content, so a path staged identically to what's on disk is indistinguishable
    from an ordinary clean file - there's nothing left recorded anywhere that says "this differs
    from the old branch tip". `checkout` (and `reset --hard`) would then silently
    overwrite/discard it with zero warning.

    Fixed by giving `Restore-PsGitTree` a real third tree to compare against: a new `-OldId`
    parameter (the commit checked out immediately before the restore) that
    `Invoke-PsGitCommand`'s 'checkout' case now always passes (from `$prevHead.Id`, captured
    before the switch). With it, `-PreserveUnaffectedEdits` and the uncommitted-edit conflict
    check both compare against the real old tree instead of the index, and a preserved path's
    index entry is carried forward as whatever the index already holds for it (not silently reset
    to the target's id) so a staged edit still shows up staged afterward instead of vanishing. The
    same three-way reasoning was applied to the phase-1b removal path too (see the last Describe
    block: a staged brand-new file, tracked in neither branch's tree, was at identical risk).
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitStagedEditRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    'original' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
    Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
    Invoke-PsGitCommand -CommandInput 'commit -m "initial"' -RepoPath $repo
    return $repo
}

Describe 'Issue #34: a staged edit survives switching to a branch with identical committed content' {

    It 'the exact reported repro: stage an edit, branch, checkout - the staged edit is still there and still staged' {
        $repo = New-PsGitStagedEditRepo 'repro-staged'
        'STAGED EDIT' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo

        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'STAGED EDIT'
        $st = Get-PsGitStatus -RepoPath $repo
        $st.Branch | Should Be 'mybranch'
        @($st.Staged | Where-Object { $_.Path -eq 'firstfile.txt' -and $_.State -eq 'modified' }).Count | Should Be 1
        @($st.Unstaged | Where-Object { $_.Path -eq 'firstfile.txt' }).Count | Should Be 0
    }

    It 'switching back to the original branch still carries the same staged edit, still staged' {
        $repo = New-PsGitStagedEditRepo 'repro-staged-roundtrip'
        'STAGED EDIT' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo

        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'STAGED EDIT'
        $st = Get-PsGitStatus -RepoPath $repo
        $st.Branch | Should Be 'main'
        @($st.Staged | Where-Object { $_.Path -eq 'firstfile.txt' -and $_.State -eq 'modified' }).Count | Should Be 1
    }

    It 'a staged edit that is then further edited on disk (staged AND unstaged at once) survives with both states intact' {
        $repo = New-PsGitStagedEditRepo 'repro-staged-plus-unstaged'
        'STAGED EDIT' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        'FURTHER UNSTAGED EDIT' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo

        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'FURTHER UNSTAGED EDIT'
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged | Where-Object { $_.Path -eq 'firstfile.txt' -and $_.State -eq 'modified' }).Count | Should Be 1
        @($st.Unstaged | Where-Object { $_.Path -eq 'firstfile.txt' -and $_.State -eq 'modified' }).Count | Should Be 1
    }

    It 'an unrelated staged edit to a different file is untouched and never blocks the switch' {
        $repo = New-PsGitStagedEditRepo 'repro-staged-unrelated'
        'second' | Set-Content -LiteralPath (Join-Path $repo 'secondfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "add second"' -RepoPath $repo
        'STAGED SECOND EDIT' | Set-Content -LiteralPath (Join-Path $repo 'secondfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        { Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo } | Should Not Throw
        (Get-Content -LiteralPath (Join-Path $repo 'secondfile.txt') -Raw) | Should Be 'STAGED SECOND EDIT'
    }
}

Describe 'Issue #34: a genuine conflict against a staged edit is still refused, not silently discarded or clobbered' {

    It 'refuses (with a message naming the path) when the target branch really did change the file the stage differs from' {
        $repo = New-PsGitStagedEditRepo 'staged-conflict-refuse'
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        'mybranch content' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "mybranch changes firstfile"' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo
        'my staged conflict edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo

        $out = Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match "firstfile.txt' has uncommitted changes"
        $st = Get-PsGitStatus -RepoPath $repo
        $st.Branch | Should Be 'main'
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'my staged conflict edit'
        @($st.Staged | Where-Object { $_.Path -eq 'firstfile.txt' -and $_.State -eq 'modified' }).Count | Should Be 1
    }

    It '-f/--force discards a genuine staged conflict and completes the switch, matching real git checkout -f' {
        $repo = New-PsGitStagedEditRepo 'staged-conflict-force'
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo
        'mybranch content' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "mybranch changes firstfile"' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout main' -RepoPath $repo
        'my staged conflict edit' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo

        $out = Invoke-PsGitCommand -CommandInput 'checkout -f mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Checked out mybranch'
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'mybranch content'
        (Get-PsGitStatus -RepoPath $repo).Branch | Should Be 'mybranch'
    }
}

Describe 'Issue #34: git reset --hard is unaffected - it still discards a staged edit too' {
    <#
    `git reset --hard` never passes -PreserveUnaffectedEdits (see Restore-PsGitTree.ps1's own
    DESCRIPTION: it restores to a tree that's frequently identical to the current index, so
    unconditional overwrite via plain -Force is the whole point), so the old/new-tree comparison
    added for #34 must never come into play there. Exercises the engine directly, same pattern as
    PsGit.CheckoutPreserveEdits.Tests.ps1's own reset --hard regression test.
    #>

    It 'Restore-PsGitTree -Force (no -PreserveUnaffectedEdits) discards a staged edit, not just an unstaged one' {
        $repo = New-PsGitStagedEditRepo 'reset-hard-staged'
        $head = (@(Get-PsGitBranch -RepoPath $repo) | Where-Object { $_.Name -eq 'main' }).Id
        'STAGED EDIT' | Set-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Restore-PsGitTree -RepoPath $repo -Id $head -Force
        (Get-Content -LiteralPath (Join-Path $repo 'firstfile.txt') -Raw) | Should Be 'original'
        @((Get-PsGitStatus -RepoPath $repo).Staged).Count | Should Be 0
    }
}

Describe 'Issue #34 edge case: a staged brand-new file, tracked in neither branch, is refused rather than silently deleted' {
    <#
    Before this fix, phase 1b's removal guard compared on-disk content to the INDEX only - for a
    path staged as a new file (present in the index, absent from both the old and target trees,
    since it was never committed anywhere), on-disk always matches the index right after `git add`,
    so the old guard saw "no conflict" and silently deleted it during a branch switch to a branch
    that also doesn't have this path. The #34 fix's three-way check catches this too: on-disk (and
    the index) diverge from the old tree's entry for this path (which doesn't exist - $null), so
    it's treated as a conflict like any other uncommitted change, refused unless -Force. NOTE: real
    git actually leaves a path like this alone entirely (it's outside the diff between the two
    trees on both sides), rather than refusing/requiring -Force - PsGit's phase 1b removes any
    index path missing from the target tree unconditionally (see #10), so getting the fully
    real-git-matching "leave it alone" behavior here would need a further, separate change. Filed
    as a follow-up rather than expanding #34's scope - see Gitea issue filed alongside this suite.
    #>

    It 'refuses (with a message naming the path) instead of silently deleting the staged new file' {
        $repo = New-PsGitStagedEditRepo 'staged-new-file-refuse'
        'brand new' | Set-Content -LiteralPath (Join-Path $repo 'newfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add newfile.txt' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo

        $out = Invoke-PsGitCommand -CommandInput 'checkout mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match "newfile.txt' has uncommitted changes"
        Test-Path -LiteralPath (Join-Path $repo 'newfile.txt') | Should Be $true
        $st = Get-PsGitStatus -RepoPath $repo
        $st.Branch | Should Be 'main'
        @($st.Staged | Where-Object { $_.Path -eq 'newfile.txt' -and $_.State -eq 'added' }).Count | Should Be 1
    }

    It '-f/--force on that same case discards the staged new file and completes the switch' {
        $repo = New-PsGitStagedEditRepo 'staged-new-file-force'
        'brand new' | Set-Content -LiteralPath (Join-Path $repo 'newfile.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add newfile.txt' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new mybranch' -RepoPath $repo

        $out = Invoke-PsGitCommand -CommandInput 'checkout -f mybranch' -RepoPath $repo 6>&1 | Out-String
        $out | Should Match 'Checked out mybranch'
        Test-Path -LiteralPath (Join-Path $repo 'newfile.txt') | Should Be $false
        (Get-PsGitStatus -RepoPath $repo).Branch | Should Be 'mybranch'
    }
}
