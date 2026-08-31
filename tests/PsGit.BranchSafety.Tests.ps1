<#
.SYNOPSIS
    Edge cases for branch isolation on checkout (#10), the reflog (#11), and the merged-branch
    guard on Remove-PsGitBranch (#12) that tests/PsGit.Adversarial.Tests.ps1 does not already
    exercise.
.DESCRIPTION
    The adversarial suite's two relevant repros only prove: a single top-level file present on
    one branch and absent from another disappears after switching (#10), and deleting a branch
    with unmerged, unreachable-elsewhere commits either throws or leaves *some* reflog directory
    behind (#11/#12 share one test, since either fix alone makes it pass). This file is scoped to
    what's left:

      - #10: a stale file's now-empty parent directory is pruned too, not just the file; a stale
        file carrying an *uncommitted* edit is refused rather than silently discarded (mirrors the
        overwrite conflict check from #8, applied to removal); -Force removes it anyway.
      - #11: the reflog lines Restore-PsGitTree/Invoke-PsGitCommand/New-PsGitCommit/New-PsGitBranch
        actually write are well-formed and land in the right file(s) - not just "some directory
        under .git/logs exists" the way the shared adversarial test checks. In particular: a plain
        checkout must append to logs/HEAD but leave the target branch's own reflog untouched,
        since the branch ref's SHA doesn't move on a plain checkout.
      - #12: isolates the merged-check from the reflog side effect - an unmerged branch delete is
        refused AND its ref file is left intact (not just "something threw"); a branch that IS
        merged deletes cleanly without needing -Force; -Force still deletes an unmerged one.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitBranchSafetyRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

function Get-PsGitReflogLastLine {
    param([Parameter(Mandatory)][string]$Path)
    $line = @(Get-Content -LiteralPath $Path)[-1]
    $tab = $line.IndexOf("`t")
    $meta = $line.Substring(0, $tab) -split ' '
    return [pscustomobject]@{ OldId = $meta[0]; NewId = $meta[1]; Message = $line.Substring($tab + 1) }
}

Describe 'BranchSafety: a stale tracked file is fully cleaned up, not just deleted (#10)' {

    It 'a file only tracked before the switch is removed, and the empty directory it leaves behind is pruned' {
        $repo = New-PsGitBranchSafetyRepo 'bs-prune'
        'k' | Set-Content -LiteralPath (Join-Path $repo 'keep.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'keep.txt'
        $base = New-PsGitCommit -RepoPath $repo -Message 'base'

        New-Item -ItemType Directory -Path (Join-Path $repo 'nested\dir') -Force | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $repo 'nested\dir\only.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'nested/dir/only.txt'
        $withNested = New-PsGitCommit -RepoPath $repo -Message 'adds nested/dir/only.txt'

        { Restore-PsGitTree -RepoPath $repo -Id $base } | Should Not Throw
        Test-Path (Join-Path $repo 'nested') | Should Be $false
        (Get-Content -LiteralPath (Join-Path $repo 'keep.txt') -Raw) | Should Be 'k'
    }

    It 'a locally modified stale file is refused, not silently discarded, by the removal side of a restore' {
        $repo = New-PsGitBranchSafetyRepo 'bs-dirty-removal'
        'k' | Set-Content -LiteralPath (Join-Path $repo 'keep.txt') -NoNewline -Encoding UTF8
        'x' | Set-Content -LiteralPath (Join-Path $repo 'stale.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'keep.txt', 'stale.txt'
        $withStale = New-PsGitCommit -RepoPath $repo -Message 'with stale'
        Remove-PsGitFile -RepoPath $repo -Path 'stale.txt'
        $withoutStale = New-PsGitCommit -RepoPath $repo -Message 'without stale'

        Restore-PsGitTree -RepoPath $repo -Id $withStale
        'MODIFIED, NEVER STAGED' | Set-Content -LiteralPath (Join-Path $repo 'stale.txt') -NoNewline -Encoding UTF8

        $threw = $false
        try { Restore-PsGitTree -RepoPath $repo -Id $withoutStale } catch { $threw = $true }
        $survived = (Get-Content -LiteralPath (Join-Path $repo 'stale.txt') -Raw) -eq 'MODIFIED, NEVER STAGED'
        ($threw -or $survived) | Should Be $true
        (Get-Content -LiteralPath (Join-Path $repo 'keep.txt') -Raw) | Should Be 'k'
    }

    It '-Force removes a locally modified stale file instead of refusing' {
        $repo = New-PsGitBranchSafetyRepo 'bs-force-removal'
        'k' | Set-Content -LiteralPath (Join-Path $repo 'keep.txt') -NoNewline -Encoding UTF8
        'x' | Set-Content -LiteralPath (Join-Path $repo 'stale.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'keep.txt', 'stale.txt'
        $withStale = New-PsGitCommit -RepoPath $repo -Message 'with stale'
        Remove-PsGitFile -RepoPath $repo -Path 'stale.txt'
        $withoutStale = New-PsGitCommit -RepoPath $repo -Message 'without stale'

        Restore-PsGitTree -RepoPath $repo -Id $withStale
        'MODIFIED, NEVER STAGED' | Set-Content -LiteralPath (Join-Path $repo 'stale.txt') -NoNewline -Encoding UTF8

        { Restore-PsGitTree -RepoPath $repo -Id $withoutStale -Force } | Should Not Throw
        Test-Path (Join-Path $repo 'stale.txt') | Should Be $false
    }
}

Describe 'BranchSafety: ref moves are recorded in the reflog (#11)' {

    It 'New-PsGitCommit appends a well-formed entry to logs/HEAD and to the current branch''s own reflog' {
        $repo = New-PsGitBranchSafetyRepo 'bs-commit-reflog'
        'a' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'first'
        'b' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $c2 = New-PsGitCommit -RepoPath $repo -Message 'second'

        $headLog = Join-Path $repo '.git\logs\HEAD'
        Test-Path $headLog | Should Be $true
        @(Get-Content -LiteralPath $headLog).Count | Should Be 2
        $last = Get-PsGitReflogLastLine -Path $headLog
        $last.OldId | Should Be $c1
        $last.NewId | Should Be $c2
        $last.Message | Should Be 'commit: second'

        $branchLog = Join-Path $repo '.git\logs\refs\heads\main'
        Test-Path $branchLog | Should Be $true
        @(Get-Content -LiteralPath $branchLog).Count | Should Be 2
    }

    It 'New-PsGitBranch records the ref''s creation with the all-zero old id' {
        $repo = New-PsGitBranchSafetyRepo 'bs-branch-create-reflog'
        'a' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'c1'
        New-PsGitBranch -RepoPath $repo -Name 'feature' -StartId $c1

        $log = Join-Path $repo '.git\logs\refs\heads\feature'
        Test-Path $log | Should Be $true
        $entry = Get-PsGitReflogLastLine -Path $log
        $entry.OldId | Should Be ('0' * 40)
        $entry.NewId | Should Be $c1
    }

    It 'checking out a branch appends to logs/HEAD but does not touch the target branch''s own reflog' {
        $repo = New-PsGitBranchSafetyRepo 'bs-checkout-reflog'
        'a' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $c1 = New-PsGitCommit -RepoPath $repo -Message 'c1'
        New-PsGitBranch -RepoPath $repo -Name 'feature' -StartId $c1

        $featureLog = Join-Path $repo '.git\logs\refs\heads\feature'
        $headLog = Join-Path $repo '.git\logs\HEAD'
        $headLinesBefore = @(Get-Content -LiteralPath $headLog).Count
        $featureLinesBefore = @(Get-Content -LiteralPath $featureLog).Count

        Invoke-PsGitCommand -CommandInput 'checkout feature' -RepoPath $repo

        @(Get-Content -LiteralPath $headLog).Count | Should Be ($headLinesBefore + 1)
        @(Get-Content -LiteralPath $featureLog).Count | Should Be $featureLinesBefore

        $last = Get-PsGitReflogLastLine -Path $headLog
        $last.Message | Should Be 'checkout: moving from main to feature'
    }
}

Describe 'BranchSafety: Remove-PsGitBranch refuses an unmerged branch unless forced (#12)' {

    It 'deleting a branch with commits unreachable from any other ref throws and leaves the branch ref intact' {
        $repo = New-PsGitBranchSafetyRepo 'bs-unmerged-refused'
        'a' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $base = New-PsGitCommit -RepoPath $repo -Message 'base'
        New-PsGitBranch -RepoPath $repo -Name 'doomed' -StartId $base
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/doomed`n")
        'b' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $doomedTip = New-PsGitCommit -RepoPath $repo -Message 'unmerged work'
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/main`n")

        { Remove-PsGitBranch -RepoPath $repo -Name 'doomed' } | Should Throw
        $refFile = Join-Path $repo '.git\refs\heads\doomed'
        Test-Path $refFile | Should Be $true
        (Get-Content -LiteralPath $refFile -Raw).Trim() | Should Be $doomedTip
    }

    It 'deleting a branch that IS fully merged into another ref succeeds without -Force' {
        $repo = New-PsGitBranchSafetyRepo 'bs-merged-deletes-clean'
        'a' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $base = New-PsGitCommit -RepoPath $repo -Message 'base'
        New-PsGitBranch -RepoPath $repo -Name 'feature' -StartId $base
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/feature`n")
        'b' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $featureTip = New-PsGitCommit -RepoPath $repo -Message 'feature work'
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/main`n")
        # fast-forward main to include feature's work, simulating a merge
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\refs\heads\main'), "$featureTip`n")

        { Remove-PsGitBranch -RepoPath $repo -Name 'feature' } | Should Not Throw
        Test-Path (Join-Path $repo '.git\refs\heads\feature') | Should Be $false
    }

    It '-Force deletes an unmerged branch anyway' {
        $repo = New-PsGitBranchSafetyRepo 'bs-force-delete'
        'a' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $base = New-PsGitCommit -RepoPath $repo -Message 'base'
        New-PsGitBranch -RepoPath $repo -Name 'doomed' -StartId $base
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/doomed`n")
        'b' | Set-Content -LiteralPath (Join-Path $repo 'f.txt') -NoNewline -Encoding UTF8
        Add-PsGitFile -RepoPath $repo -Path 'f.txt'
        $null = New-PsGitCommit -RepoPath $repo -Message 'unmerged work'
        [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/main`n")

        { Remove-PsGitBranch -RepoPath $repo -Name 'doomed' -Force } | Should Not Throw
        Test-Path (Join-Path $repo '.git\refs\heads\doomed') | Should Be $false
    }
}
