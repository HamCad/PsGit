<#
.SYNOPSIS
    Edge cases for the two-phase, conflict-checked Restore-PsGitTree added for Gitea issues #8
    (silent clobber of uncommitted work) and #9 (non-atomic checkout) that
    tests/PsGit.Adversarial.Tests.ps1 does not already exercise.
.DESCRIPTION
    The adversarial suite covers the two headline repros: a plain uncommitted edit being
    silently discarded, and a read-only file mid-restore leaving a mixed old/new working tree.
    This file is scoped to what's left:

      - '-Force' actually does override a real conflict (the adversarial suite only proves the
        *default* refuses; nothing proves Force still works).
      - An untracked file colliding with a restore target is treated the same as a tracked one
        (the adversarial repro's file was already tracked at the time it was edited).
      - On-disk content that already matches the restore target is never flagged as a conflict,
        even when the index itself is stale relative to it - the fast path must key off actual
        content, not a stale index record.
      - A file the user deleted out from under a tracked path is recreated, not mistaken for a
        conflict.
      - A write failure that phase 1's read-only pre-check can't see (an open file handle, e.g.
        antivirus/another process - not just the IsReadOnly attribute the adversarial suite's
        repro happens to use) still forces phase 2's write-and-roll-back path, byte-exact,
        including deleting a file that did not exist before this restore attempt, and leaves the
        index/status untouched.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitRestoreSafetyRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'RestoreSafety: -Force overrides the conflict check' {

    It 'Restore-PsGitTree -Force discards an uncommitted local edit instead of refusing' {
        $repo = New-PsGitRestoreSafetyRepo 'rs-force'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'v1'

        'UNSAVED EDIT' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8

        { Restore-PsGitTree -RepoPath $repo -Id $c1 -Force } | Should Not Throw
        (Get-Content -LiteralPath (Join-Path $repo 'f.txt') -Raw) | Should Be 'v1'
    }
}

Describe 'RestoreSafety: an untracked file in the way is a conflict too' {

    It 'a file that was never staged/committed, sitting where the restore wants to write, is refused rather than clobbered' {
        $repo = New-PsGitRestoreSafetyRepo 'rs-untracked-collision'
        'base' | Set-Content -LiteralPath (Join-Path $repo 'base.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'base.txt'
        $withoutNew = New-PsGitCommit -RepoPath $repo -Message 'no new.txt yet'
        'from-commit' | Set-Content -LiteralPath (Join-Path $repo 'new.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'new.txt'
        $withNew = New-PsGitCommit -RepoPath $repo -Message 'adds new.txt'

        # go back to the commit that doesn't have new.txt - it's removed from the index, but
        # Restore-PsGitTree never deletes files outside its target tree (issue #10, separate),
        # so drop it from disk by hand to simulate a clean "not tracked here" state.
        Restore-PsGitTree -RepoPath $repo -Id $withoutNew -Force
        Remove-Item -LiteralPath (Join-Path $repo 'new.txt') -Force -ErrorAction SilentlyContinue

        'LOCAL UNTRACKED CONTENT' | Set-Content -LiteralPath (Join-Path $repo 'new.txt') -NoNewline -Encoding UTF8

        $threw = $false
        try { Restore-PsGitTree -RepoPath $repo -Id $withNew } catch { $threw = $true }
        $survived = (Get-Content -LiteralPath (Join-Path $repo 'new.txt') -Raw) -eq 'LOCAL UNTRACKED CONTENT'
        ($threw -or $survived) | Should Be $true
    }
}

Describe 'RestoreSafety: the conflict check keys off real content, not a stale index' {

    It 'on-disk content that already matches the restore target is not flagged, even if the index disagrees' {
        $repo = New-PsGitRestoreSafetyRepo 'rs-stale-index'
        'content-A' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'x.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'content-A'

        'content-B' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'x.txt'   # index now records content-B for x.txt

        # working file is put back to exactly what $c1 will restore, WITHOUT re-staging - the
        # index is now stale (still says content-B) relative to both disk and the restore target.
        'content-A' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8

        { Restore-PsGitTree -RepoPath $repo -Id $c1 } | Should Not Throw
        (Get-Content -LiteralPath (Join-Path $repo 'x.txt') -Raw) | Should Be 'content-A'
    }

    It 'a file deleted from disk is recreated, not mistaken for an unresolved conflict' {
        $repo = New-PsGitRestoreSafetyRepo 'rs-deleted-on-disk'
        'y-content' | Set-Content -LiteralPath (Join-Path $repo 'y.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'y.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'y-content'

        Remove-Item -LiteralPath (Join-Path $repo 'y.txt') -Force

        { Restore-PsGitTree -RepoPath $repo -Id $c1 } | Should Not Throw
        (Get-Content -LiteralPath (Join-Path $repo 'y.txt') -Raw) | Should Be 'y-content'
    }
}

Describe 'RestoreSafety: a write failure phase 1 cannot see still rolls back byte-exact' {

    It 'an open-handle lock (not just the read-only attribute) triggers phase 2 rollback: unaffected files restore exactly, and a brand-new file this restore would have added is removed' {
        $repo = New-PsGitRestoreSafetyRepo 'rs-lock-rollback'
        'a-OLD' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'b-OLD' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'a.txt', 'b.txt'
        $old = New-PsGitCommit -RepoPath $repo -Message 'old'

        'a-NEW' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'b-NEW' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        'brand new file' | Set-Content -LiteralPath (Join-Path $repo 'brandnew.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'a.txt', 'b.txt', 'brandnew.txt'
        $new = New-PsGitCommit -RepoPath $repo -Message 'new'

        Restore-PsGitTree -RepoPath $repo -Id $old -Force
        Remove-Item -LiteralPath (Join-Path $repo 'brandnew.txt') -Force -ErrorAction SilentlyContinue
        $statusBefore = Get-PsGitStatus -RepoPath $repo

        $bPath = Join-Path $repo 'b.txt'
        $lock = [System.IO.File]::Open($bPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $threw = $false
        try {
            try { Restore-PsGitTree -RepoPath $repo -Id $new } catch { $threw = $true }
        } finally {
            $lock.Close()
        }

        $threw | Should Be $true
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw) | Should Be 'a-OLD'
        (Get-Content -LiteralPath $bPath -Raw) | Should Be 'b-OLD'
        Test-Path (Join-Path $repo 'brandnew.txt') | Should Be $false

        $statusAfter = Get-PsGitStatus -RepoPath $repo
        @($statusAfter.Staged).Count | Should Be @($statusBefore.Staged).Count
        @($statusAfter.Unstaged).Count | Should Be @($statusBefore.Unstaged).Count
    }
}
