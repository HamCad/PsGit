<#
.SYNOPSIS
    Adversarial safety suite: tries to make PsGit destroy, leak, or corrupt data the way real git
    never would. Every It block asserts the SAFE behavior a production version-control tool must
    have; a red result here means PsGit can currently damage a working tree or repository, not
    that the test is wrong.
.DESCRIPTION
    Independent of tests/PsGit.RoundTrip.Tests.ps1, tests/PsGit.Fixtures.Tests.ps1, and
    tests/PsGit.Compat.Tests.ps1 - written from scratch against the shipped behavior, not derived
    from or overlapping with them. Each scenario below was hand-verified against a live PowerShell
    5.1 engine before being written up here; none of these are speculative "what if" checks.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitAdvRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'Adversarial: uncommitted work must survive a tree restore' {

    It 'Restore-PsGitTree does not silently discard an uncommitted local edit' {
        $repo = New-PsGitAdvRepo 'adv-clobber'
        'v1' | Set-Content -LiteralPath (Join-Path $repo 'important.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'important.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'v1'

        'UNSAVED USER EDIT' | Set-Content -LiteralPath (Join-Path $repo 'important.txt') -NoNewline -Encoding UTF8

        # A safe engine must either refuse (throw) or otherwise not overwrite a working file whose
        # content differs from both HEAD and the restore target without being asked to. It must
        # NOT silently succeed and destroy the edit.
        $threw = $false
        try { Restore-PsGitTree -RepoPath $repo -Id $c1 } catch { $threw = $true }
        $survived = (Get-Content -LiteralPath (Join-Path $repo 'important.txt') -Raw) -eq 'UNSAVED USER EDIT'
        ($threw -or $survived) | Should Be $true
    }
}

Describe 'Adversarial: tree/index paths must stay inside the repository' {

    It 'a path entry containing ".." is rejected, not written outside the repo root' {
        $repo = New-PsGitAdvRepo 'adv-traversal'
        $outside = Join-Path (Split-Path -Parent $repo) 'OUTSIDE_SENTINEL.txt'
        'do not touch me' | Set-Content -LiteralPath $outside -NoNewline -Encoding UTF8
        $global:PsGitAdvRepo = $repo
        $global:PsGitAdvRelOutside = '../' + (Split-Path -Leaf $outside)

        $threw = $false
        try {
            InModuleScope PsGit {
                $blobId = Write-PsGitObject -RepoPath $global:PsGitAdvRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('PWNED'))
                $entries = @([pscustomobject]@{ Path = $global:PsGitAdvRelOutside; Mode = '100644'; Id = $blobId; Size = 5 })
                $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitAdvRepo -Entries $entries
                Restore-PsGitTree -RepoPath $global:PsGitAdvRepo -Id $treeId
            }
        } catch { $threw = $true }

        $victimContent = Get-Content -LiteralPath $outside -Raw
        Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue
        ($threw -or $victimContent -notmatch 'PWNED') | Should Be $true
    }

    It 'a path entry with a ".git" component is rejected, not allowed to overwrite git''s own control files' {
        $repo = New-PsGitAdvRepo 'adv-dotgit'
        $global:PsGitAdvRepo = $repo

        $threw = $false
        try {
            InModuleScope PsGit {
                $blobId = Write-PsGitObject -RepoPath $global:PsGitAdvRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('PWNED'))
                $entries = @([pscustomobject]@{ Path = '.git/config'; Mode = '100644'; Id = $blobId; Size = 5 })
                $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitAdvRepo -Entries $entries
                Restore-PsGitTree -RepoPath $global:PsGitAdvRepo -Id $treeId
            }
        } catch { $threw = $true }

        $config = Get-Content -LiteralPath (Join-Path $repo '.git\config') -Raw
        ($threw -or $config -notmatch 'PWNED') | Should Be $true
    }
}

Describe 'Adversarial: switching branches must not leak files between them' {

    It 'a file present only on branch A is removed from the working tree after switching to branch B' {
        $repo = New-PsGitAdvRepo 'adv-branch-leak'
        'secret' | Set-Content -LiteralPath (Join-Path $repo 'secret.txt') -NoNewline -Encoding UTF8
        'common' | Set-Content -LiteralPath (Join-Path $repo 'common.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'secret.txt', 'common.txt'
        $withSecret = New-PsGitCommit -RepoPath $repo -Message 'has secret'
        New-PsGitBranch -RepoPath $repo -Name 'public' -StartId $withSecret

        Restore-PsGitTree -RepoPath $repo -Id $withSecret
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/public`n")
        Remove-PsGitFile -RepoPath $repo -Path 'secret.txt'
        Remove-Item -LiteralPath (Join-Path $repo 'secret.txt') -Force
        Add-PsGitFile -RepoPath $repo -Path 'common.txt'
        $publicHead = New-PsGitCommit -RepoPath $repo -Message 'public: no secret'

        # simulate returning to a branch that has secret.txt, then switching back to public
        Restore-PsGitTree -RepoPath $repo -Id $withSecret
        Restore-PsGitTree -RepoPath $repo -Id $publicHead

        Test-Path (Join-Path $repo 'secret.txt') | Should Be $false
    }
}

Describe 'Adversarial: a failed restore must not leave a corrupted, half-old/half-new working tree' {

    It 'if writing one file fails mid-restore, no other file is silently advanced past the last known-good state' {
        $repo = New-PsGitAdvRepo 'adv-atomic'
        'a-OLD' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'b-OLD' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        'c-OLD' | Set-Content -LiteralPath (Join-Path $repo 'c.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'a.txt', 'b.txt', 'c.txt'
        $old = New-PsGitCommit -RepoPath $repo -Message 'old'
        'a-NEW' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -NoNewline -Encoding UTF8
        'b-NEW' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -NoNewline -Encoding UTF8
        'c-NEW' | Set-Content -LiteralPath (Join-Path $repo 'c.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'a.txt', 'b.txt', 'c.txt'
        $new = New-PsGitCommit -RepoPath $repo -Message 'new'

        Restore-PsGitTree -RepoPath $repo -Id $old
        Set-ItemProperty -LiteralPath (Join-Path $repo 'b.txt') -Name IsReadOnly -Value $true
        try { Restore-PsGitTree -RepoPath $repo -Id $new } catch { }
        Set-ItemProperty -LiteralPath (Join-Path $repo 'b.txt') -Name IsReadOnly -Value $false

        $a = Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw
        $c = Get-Content -LiteralPath (Join-Path $repo 'c.txt') -Raw
        # a safe (atomic-or-fail-clean) restore must not advance a.txt to NEW while c.txt is
        # still OLD - that mixed state cannot arise from any real git operation
        (($a -match 'NEW') -and ($c -match 'OLD')) | Should Be $false
    }
}

Describe 'Adversarial: destructive branch/ref operations must be recoverable' {

    It 'deleting a branch does not silently discard the only reference to its unmerged commits' {
        $repo = New-PsGitAdvRepo 'adv-branchdel'
        'base' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $base = New-PsGitCommit -RepoPath $repo -Message 'base'
        New-PsGitBranch -RepoPath $repo -Name 'doomed' -StartId $base
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/doomed`n")
        'unmerged work' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $doomedCommit = New-PsGitCommit -RepoPath $repo -Message 'important unmerged work'
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/main`n")

        $threw = $false
        try { Remove-PsGitBranch -RepoPath $repo -Name 'doomed' } catch { $threw = $true }

        # either the engine refuses to delete an unmerged branch, or it leaves a reflog trail
        # (.git/logs/...) a user could use to recover $doomedCommit
        $reflogExists = Test-Path (Join-Path $repo '.git\logs')
        ($threw -or $reflogExists) | Should Be $true
    }
}

Describe 'Adversarial: the native git-style CLI must handle ordinary filenames' {

    It 'git add "<file with a space>.txt" actually stages the file' {
        $repo = New-PsGitAdvRepo 'adv-spaces'
        'meeting notes' | Set-Content -LiteralPath (Join-Path $repo 'Meeting Notes.docx') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add "Meeting Notes.docx"' -RepoPath $repo
        $st = Get-PsGitStatus -RepoPath $repo
        @($st.Staged).Count | Should Be 1
    }
}

Describe 'Adversarial: ref/branch names that collide with Windows reserved device names' {

    It 'creating a branch named after a reserved device name either fails loudly or actually persists' {
        $repo = New-PsGitAdvRepo 'adv-devname'
        'x' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'x.txt'
        $null = New-PsGitCommit -RepoPath $repo -Message 'x'

        $threw = $false
        try { New-PsGitBranch -RepoPath $repo -Name 'con' } catch { $threw = $true }
        $persisted = Test-Path (Join-Path $repo '.git\refs\heads\con')
        # must not report success while silently creating nothing
        ($threw -or $persisted) | Should Be $true
    }
}

Describe 'Adversarial: commit must refuse a no-op when explicitly given a message' {

    It '"commit -m" with nothing staged does not create a duplicate empty commit' {
        $repo = New-PsGitAdvRepo 'adv-emptycommit'
        Invoke-PsGitCommand -CommandInput 'init' -RepoPath $repo
        'x' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "first"' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "nothing changed"' -RepoPath $repo
        $log = @(Get-PsGitLog -RepoPath $repo)
        $log.Count | Should Be 1
    }
}
