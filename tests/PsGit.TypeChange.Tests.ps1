<#
.SYNOPSIS
    Restore-PsGitTree across a commit boundary where a tracked path changes TYPE - a directory in
    one commit and a blob or symlink (mode 120000) entry in the other, or vice versa - sourced
    from mining git/git's own t2007-checkout-symlink.sh / t2021-checkout-overwrite.sh for PsGit
    test scenarios (Gitea #23, git-t-mining candidates #1/#2).
.DESCRIPTION
    Before this fix, Restore-PsGitTree treated every entry as a same-type overwrite: writing a
    blob to a path that is currently a directory called [System.IO.File]::ReadAllBytes on a
    directory (throws a raw UnauthorizedAccessException-wrapped MethodInvocationException);
    creating a directory at a path that is currently a file hit New-Item/WriteAllBytes failing
    with a raw DirectoryNotFoundException-wrapped one instead. Confirmed on Creo before this fix:
    both directions failed safely (no data corruption - the old state was always left intact,
    since the plan always attempted writes before removals and the mismatch aborted phase 1/2
    before anything destructive happened) but with a confusing raw .NET exception rather than a
    clear refusal, and a *successful* type change (no untracked-file conflict) never worked at
    all - checkout just always failed. Confirmed separately (git-t-mining candidate #2) that an
    untracked file sitting inside a directory being replaced was never actually lost by the old
    code either, just protected by the same accidental all-or-nothing failure.

    Fixed by detecting a directory-vs-blob type change in phase 1 (Public/Restore-PsGitTree.ps1):
    - if nothing untracked is left behind once the directory's own tracked children are removed
      by the ordinary phase-1b plan, phase 2 now runs removals before writes and clears the
      now-empty directory husk immediately before writing the replacing blob/symlink - so the
      type change actually succeeds instead of always throwing.
    - if something untracked WOULD be destroyed to make room, the whole restore is refused up
      front with a message naming the untracked path - not overridable by -Force, which only ever
      waives checks on tracked content.
    Mode 120000 (symlink) entries get no special handling elsewhere in PsGit (confirmed via
    `grep -rn "120000"` before this fix returning nothing) - Restore-PsGitTree just writes their
    blob content (the link target text) as an ordinary file, matching real git's own behavior
    when running without symlink privileges (core.symlinks=false), which is the only mode Creo's
    unprivileged test account can exercise.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention. The plain directory<->file scenarios use the real Add-PsGitFile/
    Remove-PsGitFile/New-PsGitCommit flow (no NTFS restriction blocks representing them as real
    files); the mode-120000 scenarios build tree/commit objects directly via PsGit's own private
    write functions, the same synthetic-construction pattern as PsGit.EdgeCases.Tests.ps1, since
    Add-PsGitFile has no way to stage a mode-120000 entry at all.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitTypeChangeRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

function New-PsGitSymlinkModeCommit {
    <# .SYNOPSIS Build a commit whose tree replaces/is replaced-by a mode-120000 'foo' entry, via synthetic object construction (no real Add-PsGitFile symlink support exists). #>
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][object[]]$Entries, [string]$ParentId)
    $global:PsGitTcRepo = $Repo
    $global:PsGitTcEntries = $Entries
    $global:PsGitTcParent = $ParentId
    InModuleScope PsGit {
        $tree = ConvertTo-PsGitTree -RepoPath $global:PsGitTcRepo -Entries $global:PsGitTcEntries
        $stamp = Format-PsGitIdentityTimestamp -Date ([System.DateTimeOffset]::Now)
        $parentLine = if ($global:PsGitTcParent) { "parent $($global:PsGitTcParent)`n" } else { '' }
        $commitText = "tree $tree`n$($parentLine)author Test <test@localhost> $stamp`ncommitter Test <test@localhost> $stamp`n`ntype-change`n"
        Write-PsGitObject -RepoPath $global:PsGitTcRepo -Type 'commit' -Content ([System.Text.Encoding]::UTF8.GetBytes($commitText))
    }
}

function Write-PsGitBlobDirect {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Text)
    $global:PsGitTcRepo = $Repo
    $global:PsGitTcText = $Text
    InModuleScope PsGit {
        Write-PsGitObject -RepoPath $global:PsGitTcRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes($global:PsGitTcText))
    }
}

Describe 'TypeChange: directory <-> plain file across a restore' {

    It 'restores a directory replaced by a file: old tracked children are gone, the new file is written, the index reflects only the new entry' {
        $repo = New-PsGitTypeChangeRepo 'tc-dir-to-file'
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        'bbb' | Set-Content -LiteralPath (Join-Path $repo 'foo/b.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt', 'foo/b.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'dir version'

        Remove-PsGitFile -RepoPath $repo -Path 'foo/a.txt', 'foo/b.txt'
        Remove-Item -LiteralPath (Join-Path $repo 'foo') -Recurse -Force
        'file version' | Set-Content -LiteralPath (Join-Path $repo 'foo') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo'
        $c2 = New-PsGitCommit -RepoPath $repo -Message 'file version'

        { Restore-PsGitTree -RepoPath $repo -Id $c2 } | Should Not Throw
        $item = Get-Item -LiteralPath (Join-Path $repo 'foo') -Force
        $item.PSIsContainer | Should Be $false
        (Get-Content -LiteralPath (Join-Path $repo 'foo') -Raw) | Should Be 'file version'

        $status = Get-PsGitStatus -RepoPath $repo
        @($status.Staged).Count | Should Be 0
        @($status.Unstaged).Count | Should Be 0
    }

    It 'restores a file replaced by a directory: old tracked file is gone, the new children are written' {
        $repo = New-PsGitTypeChangeRepo 'tc-file-to-dir'
        'file version' | Set-Content -LiteralPath (Join-Path $repo 'foo') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'file version'

        Remove-PsGitFile -RepoPath $repo -Path 'foo'
        Remove-Item -LiteralPath (Join-Path $repo 'foo') -Force
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        'bbb' | Set-Content -LiteralPath (Join-Path $repo 'foo/b.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt', 'foo/b.txt'
        $c2 = New-PsGitCommit -RepoPath $repo -Message 'dir version'

        Restore-PsGitTree -RepoPath $repo -Id $c1 -Force | Out-Null

        { Restore-PsGitTree -RepoPath $repo -Id $c2 } | Should Not Throw
        $item = Get-Item -LiteralPath (Join-Path $repo 'foo') -Force
        $item.PSIsContainer | Should Be $true
        (Get-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -Raw) | Should Be 'aaa'
        (Get-Content -LiteralPath (Join-Path $repo 'foo/b.txt') -Raw) | Should Be 'bbb'
    }

    It 'refuses a directory-to-file type change when an untracked file sits inside the directory, and leaves everything untouched' {
        $repo = New-PsGitTypeChangeRepo 'tc-untracked-blocks'
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'dir version'

        # Build c2 with 'foo' as a file without ever touching the real 'foo' directory on disk -
        # simulates a type change authored on another branch/machine.
        $idFile = Write-PsGitBlobDirect -Repo $repo -Text 'file version'
        $c2 = New-PsGitSymlinkModeCommit -Repo $repo -Entries @([pscustomobject]@{ Path = 'foo'; Mode = '100644'; Id = $idFile }) -ParentId $c1

        'PRECIOUS UNTRACKED DATA' | Set-Content -LiteralPath (Join-Path $repo 'foo/untracked.txt') -NoNewline -Encoding UTF8

        { Restore-PsGitTree -RepoPath $repo -Id $c2 } | Should Throw

        (Get-Content -LiteralPath (Join-Path $repo 'foo/untracked.txt') -Raw) | Should Be 'PRECIOUS UNTRACKED DATA'
        (Get-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -Raw) | Should Be 'aaa'
        (Get-Item -LiteralPath (Join-Path $repo 'foo') -Force).PSIsContainer | Should Be $true
    }

    It '-Force does not override the untracked-leftover refusal for a directory-to-file type change' {
        $repo = New-PsGitTypeChangeRepo 'tc-untracked-force'
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'dir version'
        $idFile = Write-PsGitBlobDirect -Repo $repo -Text 'file version'
        $c2 = New-PsGitSymlinkModeCommit -Repo $repo -Entries @([pscustomobject]@{ Path = 'foo'; Mode = '100644'; Id = $idFile }) -ParentId $c1

        'PRECIOUS UNTRACKED DATA' | Set-Content -LiteralPath (Join-Path $repo 'foo/untracked.txt') -NoNewline -Encoding UTF8

        { Restore-PsGitTree -RepoPath $repo -Id $c2 -Force } | Should Throw
        Test-Path -LiteralPath (Join-Path $repo 'foo/untracked.txt') | Should Be $true
    }

    It 'rolls back a directory-to-file type change cleanly if a later step in the same restore fails, recreating the directory and its tracked files byte-exact' {
        # 'z.txt' is named to sort AFTER 'foo' so the type-change write (clear the 'foo' directory
        # husk, then write the replacing blob) has already run by the time the lock is hit -
        # exercising the rollback path that must recreate 'foo' as a directory again, not just
        # restore a same-type file in place.
        $repo = New-PsGitTypeChangeRepo 'tc-rollback'
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        'zOLD' | Set-Content -LiteralPath (Join-Path $repo 'z.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt', 'z.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'dir + z-old'

        Remove-PsGitFile -RepoPath $repo -Path 'foo/a.txt'
        Remove-Item -LiteralPath (Join-Path $repo 'foo') -Recurse -Force
        'file version' | Set-Content -LiteralPath (Join-Path $repo 'foo') -NoNewline -Encoding UTF8
        'zNEW' | Set-Content -LiteralPath (Join-Path $repo 'z.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo', 'z.txt'
        $c2 = New-PsGitCommit -RepoPath $repo -Message 'file version + z-new'

        Restore-PsGitTree -RepoPath $repo -Id $c1 -Force | Out-Null

        $zPath = Join-Path $repo 'z.txt'
        $lock = [System.IO.File]::Open($zPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $threw = $false
        try {
            try { Restore-PsGitTree -RepoPath $repo -Id $c2 } catch { $threw = $true }
        } finally {
            $lock.Close()
        }

        $threw | Should Be $true
        (Get-Item -LiteralPath (Join-Path $repo 'foo') -Force).PSIsContainer | Should Be $true
        (Get-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -Raw) | Should Be 'aaa'
        (Get-Content -LiteralPath $zPath -Raw) | Should Be 'zOLD'
    }
}

Describe 'TypeChange: directory <-> mode-120000 (symlink) tree entries' {

    It 'restores a directory replaced by a mode-120000 entry: no crash, the link-target text lands as a plain file' {
        $repo = New-PsGitTypeChangeRepo 'tc-dir-to-symlink'
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'dir version'

        $idLink = Write-PsGitBlobDirect -Repo $repo -Text 'target.txt'
        $c2 = New-PsGitSymlinkModeCommit -Repo $repo -Entries @([pscustomobject]@{ Path = 'foo'; Mode = '120000'; Id = $idLink }) -ParentId $c1

        { Restore-PsGitTree -RepoPath $repo -Id $c2 } | Should Not Throw
        $item = Get-Item -LiteralPath (Join-Path $repo 'foo') -Force
        $item.PSIsContainer | Should Be $false
        (Get-Content -LiteralPath (Join-Path $repo 'foo') -Raw) | Should Be 'target.txt'
    }

    It 'restores a mode-120000 entry replaced by a directory' {
        $repo = New-PsGitTypeChangeRepo 'tc-symlink-to-dir'
        $idLink = Write-PsGitBlobDirect -Repo $repo -Text 'target.txt'
        $c1 = New-PsGitSymlinkModeCommit -Repo $repo -Entries @([pscustomobject]@{ Path = 'foo'; Mode = '120000'; Id = $idLink })
        Restore-PsGitTree -RepoPath $repo -Id $c1 | Out-Null

        $idA = Write-PsGitBlobDirect -Repo $repo -Text 'aaa'
        $c2 = New-PsGitSymlinkModeCommit -Repo $repo -Entries @([pscustomobject]@{ Path = 'foo/a.txt'; Mode = '100644'; Id = $idA }) -ParentId $c1

        { Restore-PsGitTree -RepoPath $repo -Id $c2 } | Should Not Throw
        $item = Get-Item -LiteralPath (Join-Path $repo 'foo') -Force
        $item.PSIsContainer | Should Be $true
        (Get-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -Raw) | Should Be 'aaa'
    }

    It 'refuses a directory-to-mode-120000 type change when an untracked file sits inside the directory' {
        $repo = New-PsGitTypeChangeRepo 'tc-symlink-untracked-blocks'
        New-Item -ItemType Directory -Path (Join-Path $repo 'foo') -Force | Out-Null
        'aaa' | Set-Content -LiteralPath (Join-Path $repo 'foo/a.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'foo/a.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'dir version'

        $idLink = Write-PsGitBlobDirect -Repo $repo -Text 'target.txt'
        $c2 = New-PsGitSymlinkModeCommit -Repo $repo -Entries @([pscustomobject]@{ Path = 'foo'; Mode = '120000'; Id = $idLink }) -ParentId $c1

        'PRECIOUS UNTRACKED DATA' | Set-Content -LiteralPath (Join-Path $repo 'foo/untracked.txt') -NoNewline -Encoding UTF8

        { Restore-PsGitTree -RepoPath $repo -Id $c2 } | Should Throw
        (Get-Content -LiteralPath (Join-Path $repo 'foo/untracked.txt') -Raw) | Should Be 'PRECIOUS UNTRACKED DATA'
    }
}
