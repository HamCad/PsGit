<#
.SYNOPSIS
    Advanced/adversarial edge cases discovered by direct code review, built entirely from
    synthetic data (no real-git fixture) so every scenario runs live against a real PsGit engine
    on the Windows PS5.1 target - this is deliberate where tests/PsGit.CrossCompat.Tests.ps1 (the
    real-git-fixture suite) can't reach the same ground: several of these paths (two files
    differing only by case, a file literally named 'con') can't physically coexist as real files
    on Windows/NTFS at all, so the only way to actually exercise PsGit's own behavior against
    them is to build the git OBJECTS directly (blobs/trees/commits/index entries) and never touch
    the filesystem for the colliding paths themselves.
.DESCRIPTION
    Independent of every existing test file - written from scratch against the shipped behavior,
    not derived from or overlapping with PsGit.RoundTrip.Tests.ps1, PsGit.Fixtures.Tests.ps1,
    PsGit.Adversarial.Tests.ps1, PsGit.PathSafety.Tests.ps1, PsGit.RefSafety.Tests.ps1,
    PsGit.BranchSafety.Tests.ps1, PsGit.RestoreSafety.Tests.ps1, PsGit.AddArgParse.Tests.ps1, or
    PsGit.NoOpCommit.Tests.ps1. Each scenario below was reasoned through against the actual
    Private/Public source (not a speculative "what if"), same standard as the existing
    adversarial suite's own header comment sets.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitEdgeRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

# ======================================================================================= A/B/C =
Describe 'EdgeCase: PowerShell''s case-insensitive @{} hashtable vs. git''s case-sensitive paths' {
    <#
    PowerShell's @{} / [ordered]@{} hashtable LITERAL uses a case-INSENSITIVE comparer for string
    keys by default (a well-known PS quirk, unrelated to any filesystem). Git itself is always
    case-sensitive for tree/index paths - see PsGit.CrossCompat.Tests.ps1's history/case-clash
    branch for real-git proof that 'Config.txt' and 'config.txt' can legitimately coexist as two
    distinct blobs in one tree. Three call sites key a path-indexed dictionary this way:

      1. ConvertTo-PsGitTree's $dirs ordered hashtable - groups entries by their FIRST path
         segment (directory name) before recursing. Two case-variant directory names collide
         here (e.g. 'Lib/a.txt' + 'lib/b.txt'), silently merging what should be two separate
         subtrees into one.
      2. Get-PsGitStatus's $headMap / $idxMap - keyed by the full flattened path (post
         Expand-PsGitTree / Read-PsGitIndex, so single-level file names collide here too, not
         just directory names).
      3. Add-PsGitFile's $byPath - same shape as #2, reachable any time `git add` runs against an
         index that already carries a case-variant pair from elsewhere (a restored/inherited
         tree, or synthetic construction like below).

    None of these can be reproduced by literally creating two same-named-but-cased files on disk
    - NTFS won't allow it - so every test below builds the git objects/index bytes directly via
    PsGit's own private write functions instead.
    #>

    It 'ConvertTo-PsGitTree keeps two SAME-DIRECTORY files differing only by case as distinct entries (flat files: no hashtable involved, expected to already be safe)' {
        $repo = New-PsGitEdgeRepo 'edge-case-flat'
        $global:PsGitEdgeFlatRepo = $repo
        InModuleScope PsGit {
            $upper = Write-PsGitObject -RepoPath $global:PsGitEdgeFlatRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('UPPER'))
            $lower = Write-PsGitObject -RepoPath $global:PsGitEdgeFlatRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('lower'))
            $entries = @(
                [pscustomobject]@{ Path = 'Config.txt'; Mode = '100644'; Id = $upper }
                [pscustomobject]@{ Path = 'config.txt'; Mode = '100644'; Id = $lower }
            )
            $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitEdgeFlatRepo -Entries $entries
            $back = @(Expand-PsGitTree -RepoPath $global:PsGitEdgeFlatRepo -TreeId $treeId)
            $back.Count | Should Be 2
            ($back | Where-Object { $_.Path -ceq 'Config.txt' }).Id | Should Be $upper
            ($back | Where-Object { $_.Path -ceq 'config.txt' }).Id | Should Be $lower
        }
    }

    It 'ConvertTo-PsGitTree keeps two DIRECTORIES differing only by case as distinct subtrees, not merged into one' {
        $repo = New-PsGitEdgeRepo 'edge-case-dir'
        $global:PsGitEdgeDirRepo = $repo
        InModuleScope PsGit {
            $a = Write-PsGitObject -RepoPath $global:PsGitEdgeDirRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('a'))
            $b = Write-PsGitObject -RepoPath $global:PsGitEdgeDirRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('b'))
            $entries = @(
                [pscustomobject]@{ Path = 'Lib/a.txt'; Mode = '100644'; Id = $a }
                [pscustomobject]@{ Path = 'lib/b.txt'; Mode = '100644'; Id = $b }
            )
            $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitEdgeDirRepo -Entries $entries
            $back = @(Expand-PsGitTree -RepoPath $global:PsGitEdgeDirRepo -TreeId $treeId)
            # a real, case-sensitive git would produce TWO subtrees (Lib/ and lib/) and thus two
            # flattened entries; a naive case-insensitive directory-name grouping collapses them
            # into one merged directory and silently drops one file's worth of content.
            $back.Count | Should Be 2
            (@($back | Where-Object { $_.Path -ceq 'Lib/a.txt' })).Count | Should Be 1
            (@($back | Where-Object { $_.Path -ceq 'lib/b.txt' })).Count | Should Be 1
        }
    }

    It 'Get-PsGitStatus does not silently swallow a case-only path change between HEAD and the index' {
        # Synthetic HEAD: a commit whose tree has ONLY 'config.txt' (lowercase). Synthetic INDEX:
        # a single entry 'Config.txt' (uppercase) with DIFFERENT content. Real git-correct status
        # (case-sensitive paths) is two staged changes: 'config.txt' deleted, 'Config.txt' added.
        $repo = New-PsGitEdgeRepo 'edge-case-status'
        $global:PsGitEdgeStatusRepo = $repo
        InModuleScope PsGit {
            $headBlob = Write-PsGitObject -RepoPath $global:PsGitEdgeStatusRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('lower content'))
            $headTree = ConvertTo-PsGitTree -RepoPath $global:PsGitEdgeStatusRepo -Entries @([pscustomobject]@{ Path = 'config.txt'; Mode = '100644'; Id = $headBlob })
            $stamp = Format-PsGitIdentityTimestamp -Date ([System.DateTimeOffset]::Now)
            $commitText = "tree $headTree`nauthor Test <test@localhost> $stamp`ncommitter Test <test@localhost> $stamp`n`ninitial`n"
            $commitId = Write-PsGitObject -RepoPath $global:PsGitEdgeStatusRepo -Type 'commit' -Content ([System.Text.Encoding]::UTF8.GetBytes($commitText))
            Set-PsGitRef -RepoPath $global:PsGitEdgeStatusRepo -Name 'refs/heads/main' -Id $commitId

            $idxBlob = Write-PsGitObject -RepoPath $global:PsGitEdgeStatusRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('UPPER content, genuinely different'))
            Write-PsGitIndex -RepoPath $global:PsGitEdgeStatusRepo -Entries @([pscustomobject]@{ Path = 'Config.txt'; Mode = '100644'; Id = $idxBlob; Size = 35 })

            $st = Get-PsGitStatus -RepoPath $global:PsGitEdgeStatusRepo
            $staged = @($st.Staged)
            $staged.Count | Should Be 2
            ($staged | Where-Object { $_.Path -ceq 'config.txt' }).State | Should Be 'deleted'
            ($staged | Where-Object { $_.Path -ceq 'Config.txt' }).State | Should Be 'added'
        }
    }

    It 'Add-PsGitFile does not drop a pre-existing case-variant index entry when staging an unrelated file' {
        # Simulates an index that already carries a legitimate case-variant pair (e.g. inherited
        # from a restored real-git tree, or built directly as above) - staging a totally
        # unrelated third file must not lose either of the first two on the re-serialize.
        $repo = New-PsGitEdgeRepo 'edge-case-addfile'
        'other content' | Set-Content -LiteralPath (Join-Path $repo 'other.txt') -NoNewline -Encoding UTF8
        $global:PsGitEdgeAddRepo = $repo
        InModuleScope PsGit {
            Write-PsGitIndex -RepoPath $global:PsGitEdgeAddRepo -Entries @(
                [pscustomobject]@{ Path = 'Config.txt'; Mode = '100644'; Id = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'; Size = 0 }
                [pscustomobject]@{ Path = 'config.txt'; Mode = '100644'; Id = 'ce013625030ba8dba906f756967f9e9ca394464a'; Size = 6 }
            )
        }
        Add-PsGitFile -RepoPath $repo -Path 'other.txt'
        InModuleScope PsGit {
            $entries = @(Read-PsGitIndex -RepoPath $global:PsGitEdgeAddRepo)
            $entries.Count | Should Be 3
            (@($entries | Where-Object { $_.Path -ceq 'Config.txt' })).Count | Should Be 1
            (@($entries | Where-Object { $_.Path -ceq 'config.txt' })).Count | Should Be 1
            (@($entries | Where-Object { $_.Path -ceq 'other.txt' })).Count | Should Be 1
        }
    }
}

# =================================================================================================
Describe 'EdgeCase: checking out a tracked file whose name is a Windows reserved device name' {
    <#
    Parallel gap to Gitea #14. #14 fixed exactly this class of bug (a name that silently
    redirects a file write to a Windows device instead of creating a file) for REF/BRANCH names -
    Assert-PsGitSafeRefName + a post-write Test-Path backstop in Set-PsGitRef. Tree/file paths go
    through a COMPLETELY SEPARATE check, Assert-PsGitSafeTreePath (Private/PsGitPathSafety.ps1),
    which rejects '.', '..', '.git', a literal backslash, and a drive-letter colon - and has no
    reserved-device-name check at all. Restore-PsGitTree's own write
    ([System.IO.File]::WriteAllBytes) also has no post-write verification the way Set-PsGitRef
    does. A file named 'con', 'nul.txt', etc. is completely ordinary on a Linux machine (see
    PsGit.CrossCompat.Tests.ps1's history/reserved-names branch for real-git ground truth); this
    checks what actually happens the moment PsGit itself tries to check one out, live, on the
    Windows target these device names are actually reserved on.
    #>

    foreach ($devName in @('con', 'nul.txt', 'aux', 'lpt1.log', 'com1', 'prn.dat')) {
        It "checking out a tree containing a file literally named '$devName' either fails loudly or actually creates the file with the right content" {
            $repo = New-PsGitEdgeRepo "edge-devname-$($devName -replace '[^a-zA-Z0-9]', '_')"
            $global:PsGitEdgeDevRepo = $repo
            $global:PsGitEdgeDevName = $devName
            $threw = $false
            $errMsg = $null
            try {
                InModuleScope PsGit {
                    $content = "content for $global:PsGitEdgeDevName"
                    $blobId = Write-PsGitObject -RepoPath $global:PsGitEdgeDevRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes($content))
                    $entries = @([pscustomobject]@{ Path = $global:PsGitEdgeDevName; Mode = '100644'; Id = $blobId })
                    $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitEdgeDevRepo -Entries $entries
                    Restore-PsGitTree -RepoPath $global:PsGitEdgeDevRepo -Id $treeId
                }
            } catch { $threw = $true; $errMsg = $_.Exception.Message }

            $abs = Join-Path $repo $devName
            $created = $false
            $contentOk = $false
            try {
                $created = Test-Path -LiteralPath $abs -PathType Leaf
                if ($created) { $contentOk = ((Get-Content -LiteralPath $abs -Raw) -eq "content for $devName") }
            } catch { $created = $false }

            # Must not report silent success while writing nowhere (or into the reserved device
            # instead of a real file): either Restore-PsGitTree refuses loudly (a clear, actionable
            # exception the caller can catch), or the file genuinely exists on disk with the exact
            # committed content. What it must NOT do is return normally while `con`/`nul.txt`/etc.
            # is silently absent or truncated - that is success reported for a checkout that did
            # not actually happen.
            if (-not $threw -and -not $contentOk) {
                Write-Host "  '$devName': Restore-PsGitTree returned normally but the file is missing/wrong on disk - likely redirected to the reserved device." -ForegroundColor Red
            }
            ($threw -or $contentOk) | Should Be $true
        }
    }
}

# =================================================================================================
Describe 'EdgeCase: line-ending precision (CRLF) in diff/status' {
    <#
    PsGit targets Windows, where CRLF-line-ended files are the norm (Notepad, VS Code's default
    on a fresh Windows profile, PowerShell's own Set-Content without -NoNewline). Get-PsGitDiff /
    Get-PsGitDiffLine split on a bare "`n" and keep whatever precedes it (including a trailing
    "`r") as part of each line, then compare with -ceq. As long as both sides of a comparison
    carry CRLF consistently this should already be safe (real git's own default core.autocrlf is
    false, storing raw bytes too) - this is a confirmation probe of genuinely untested territory,
    not a known bug.
    #>

    It 'editing one line of a CRLF-line-ended file reports only that line changed, not the whole file' {
        $repo = New-PsGitEdgeRepo 'edge-crlf-diff'
        $path = Join-Path $repo 'notes.txt'
        [System.IO.File]::WriteAllText($path, "line1`r`nline2`r`nline3`r`nline4`r`n", [System.Text.Encoding]::UTF8)
        Add-PsGitFile -RepoPath $repo -Path 'notes.txt'
        New-PsGitCommit -RepoPath $repo -Message 'add CRLF file' | Out-Null

        [System.IO.File]::WriteAllText($path, "line1`r`nline2-EDITED`r`nline3`r`nline4`r`n", [System.Text.Encoding]::UTF8)
        $diff = Get-PsGitDiff -RepoPath $repo -Path 'notes.txt'

        $diffLines = @($diff -split "`n")
        @($diffLines | Where-Object { $_.TrimEnd("`r") -eq '-line1' -or $_.TrimEnd("`r") -eq '-line3' -or $_.TrimEnd("`r") -eq '-line4' }).Count | Should Be 0
        @($diffLines | Where-Object { $_.TrimStart('-').TrimEnd("`r") -eq 'line2' }).Count | Should Be 1
        @($diffLines | Where-Object { $_.TrimStart('+').TrimEnd("`r") -eq 'line2-EDITED' }).Count | Should Be 1
    }
}

# =================================================================================================
Describe 'EdgeCase: UTF-8 BOM byte-exact hashing' {
    <#
    PowerShell 5.1's `Set-Content -Encoding UTF8` (and `Out-File -Encoding UTF8`) ALWAYS emits a
    UTF-8 byte-order-mark (EF BB BF) - unlike PowerShell 7+, which defaults to no-BOM. Real git
    does not strip or special-case a BOM; it hashes whatever bytes are on disk. The expected id
    below was computed independently via real `git hash-object` against the exact byte sequence
    PS5.1's Set-Content produces for this content on Windows (BOM + text + trailing CRLF, since
    Set-Content appends a newline unless -NoNewline is given).
    #>

    It 'a BOM''d file staged via Add-PsGitFile hashes to the same id real git computes for the same bytes' {
        $repo = New-PsGitEdgeRepo 'edge-bom'
        'PowerShell wrote this' | Set-Content -LiteralPath (Join-Path $repo 'bom.txt') -Encoding UTF8
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo 'bom.txt'))
        # sanity: confirm this PS5.1 host really did emit the BOM this test exists to validate
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $true

        Add-PsGitFile -RepoPath $repo -Path 'bom.txt'
        $global:PsGitEdgeBomRepo = $repo
        InModuleScope PsGit {
            $entry = @(Read-PsGitIndex -RepoPath $global:PsGitEdgeBomRepo) | Where-Object { $_.Path -eq 'bom.txt' }
            $entry.Id | Should Be 'a3d39fe831b68e5dbbdb834df2ab64a3d2fab341'
        }
    }
}

# =================================================================================================
Describe 'EdgeCase: a deeply nested path near/over Windows'' historical 260-char MAX_PATH limit' {
    <#
    .NET Framework 4.x (what PowerShell 5.1 runs on) throws PathTooLongException/
    DirectoryNotFoundException for a full path over 260 characters unless the process opts into
    Windows 10 1607+ long-path support - which is an OS/registry + app-manifest setting PsGit
    does not control and this suite cannot verify from Debian. A "production environment" claim
    needs this surfaced either way: a real, if dated, source tree (deeply nested node_modules-
    style vendoring is the classic trigger) could exceed 260 characters through entirely ordinary
    use. Tolerant like the reserved-device-name probe above: either it works, or it fails with a
    specific, expected exception - not a silent partial write.

    A .NET method called from PowerShell (e.g. [System.IO.File]::ReadAllBytes, which
    Add-PsGitFile uses) throws its real exception wrapped in a
    System.Management.Automation.MethodInvocationException - checking $_.Exception.GetType()
    only ever sees that wrapper, never the real PathTooLongException/DirectoryNotFoundException
    underneath, so the match has to walk .InnerException.
    #>

    It 'staging and restoring a file whose full repo-relative path exceeds 260 characters either works or fails with a clear PathTooLong-shaped error' {
        $repo = New-PsGitEdgeRepo 'edge-longpath'
        $segment = 'a-fairly-long-directory-segment-name'
        $relDir = (1..8 | ForEach-Object { $segment }) -join '\'
        $relPath = Join-Path $relDir 'deeply-nested-file.txt'
        $global:PsGitEdgeLongRepoLen = ($repo.Length + $relPath.Length)

        $threw = $false
        $errChain = $null
        try {
            $full = Join-Path $repo $relDir
            New-Item -ItemType Directory -Path $full -Force | Out-Null
            'deep content' | Set-Content -LiteralPath (Join-Path $repo $relPath) -NoNewline -Encoding UTF8
            Add-PsGitFile -RepoPath $repo -Path ($relPath -replace '\\', '/')
            New-PsGitCommit -RepoPath $repo -Message 'deep file' | Out-Null
        } catch {
            $threw = $true
            $types = [System.Collections.Generic.List[string]]::new()
            $ex = $_.Exception
            while ($ex) { $types.Add($ex.GetType().Name); $ex = $ex.InnerException }
            $errChain = $types -join ' -> '
        }

        if ($threw) {
            Write-Host "  path length $($global:PsGitEdgeLongRepoLen) chars -> threw $errChain" -ForegroundColor DarkGray
            $errChain | Should Match 'PathTooLong|IOException|DirectoryNotFound|UnauthorizedAccess'
        } else {
            Test-Path -LiteralPath (Join-Path $repo $relPath) | Should Be $true
        }
    }
}

# =================================================================================================
Describe 'EdgeCase: diff scale on a moderately large file (O(m*n) LCS cost probe)' {
    <#
    Get-PsGitDiffLine builds a full (m+1) x (n+1) int[,] LCS table and walks it with nested
    PowerShell loops - no chunking, no early-exit for a huge unchanged prefix/suffix, no fallback
    for large inputs (contrast Get-PsGitAdler32, which got exactly this kind of scale fix for
    Gitea #5). A single modestly-sized source file (a few thousand lines - not exotic for a real
    project) makes this quadratic in both time and memory. This is a bounded probe, not a hard
    perf gate: it flags whether an ordinary `git diff`/`git status` on a real file is reasonably
    interactive, without risking a many-minute hang if the answer turns out to be "no" - a red
    result here means profile Get-PsGitDiffLine directly, not "make this test's input bigger".
    #>

    It "diffing a ~3000-line file with scattered single-line edits completes in a reasonable time" {
        $repo = New-PsGitEdgeRepo 'edge-perf-diff'
        $lineCount = 3000
        $lines = 1..$lineCount | ForEach-Object { "line $($_.ToString('0000')): the quick brown fox jumps over the lazy dog" }
        $path = Join-Path $repo 'big.txt'
        [System.IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [System.Text.Encoding]::UTF8)
        Add-PsGitFile -RepoPath $repo -Path 'big.txt'
        New-PsGitCommit -RepoPath $repo -Message 'add big.txt' | Out-Null

        $rng = New-Object System.Random(7)
        for ($i = 0; $i -lt 40; $i++) {
            $idx = $rng.Next(0, $lineCount)
            $lines[$idx] = $lines[$idx] + ' [edited]'
        }
        [System.IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [System.Text.Encoding]::UTF8)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $diff = Get-PsGitDiff -RepoPath $repo -Path 'big.txt'
        $sw.Stop()
        Write-Host "  $lineCount-line diff with 40 scattered edits took $($sw.Elapsed.TotalSeconds) sec" -ForegroundColor DarkGray

        $diff | Should Not Be $null
        $sw.Elapsed.TotalSeconds | Should BeLessThan 30
    }
}

# =================================================================================================
Describe 'EdgeCase: rapid branch swapping and detached-HEAD checkout, three-way (extends the existing single-swap branch-leak coverage)' {
    <#
    PsGit.Adversarial.Tests.ps1 already covers a single A/B branch swap losing a file. This
    exercises the pattern the user prompt specifically asked for: several branches with
    divergent, partially-overlapping file sets, swapped back and forth repeatedly (not just
    once), PLUS a detached-HEAD checkout by raw commit sha in the middle of the sequence (real
    git supports checking out a bare commit id; Invoke-PsGitCommand's 'checkout' case falls
    through to Resolve-PsGitId for exactly this when the name isn't a branch) - asserting the
    working tree exactly matches the target at every single step along the way, not just the
    start and end.
    #>

    It 'the working tree exactly matches each branch/commit after every step of a repeated swap sequence, including a detached-HEAD stop' {
        $repo = New-PsGitEdgeRepo 'edge-branch-swap'

        'alpha only' | Set-Content -LiteralPath (Join-Path $repo 'alpha.txt') -NoNewline -Encoding UTF8
        'shared v1' | Set-Content -LiteralPath (Join-Path $repo 'shared.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "alpha base"' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new alpha' -RepoPath $repo

        Invoke-PsGitCommand -CommandInput 'branch new beta' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout beta' -RepoPath $repo
        Remove-Item -LiteralPath (Join-Path $repo 'alpha.txt') -Force
        'beta only' | Set-Content -LiteralPath (Join-Path $repo 'beta.txt') -NoNewline -Encoding UTF8
        'shared v2 (beta edit)' | Set-Content -LiteralPath (Join-Path $repo 'shared.txt') -NoNewline -Encoding UTF8
        Remove-PsGitFile -RepoPath $repo -Path 'alpha.txt'
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "beta diverges"' -RepoPath $repo
        $global:PsGitEdgeBranchRepo = $repo
        InModuleScope PsGit { $global:PsGitEdgeBetaId = (Get-PsGitHead -RepoPath $global:PsGitEdgeBranchRepo).Id }

        # 'gamma' is branched from 'alpha' (not 'beta'): it inherits alpha.txt, not beta.txt.
        Invoke-PsGitCommand -CommandInput 'checkout alpha' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'branch new gamma' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'checkout gamma' -RepoPath $repo
        'gamma only' | Set-Content -LiteralPath (Join-Path $repo 'gamma.txt') -NoNewline -Encoding UTF8
        'shared v3 (gamma edit)' | Set-Content -LiteralPath (Join-Path $repo 'shared.txt') -NoNewline -Encoding UTF8
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "gamma diverges"' -RepoPath $repo

        # gamma (current) -> alpha -> beta -> detached at beta's raw sha -> gamma -> alpha, and
        # verify the exact file set + content at every single stop, not just first/last.
        (Get-Content -LiteralPath (Join-Path $repo 'gamma.txt') -Raw) | Should Be 'gamma only'
        (Get-Content -LiteralPath (Join-Path $repo 'shared.txt') -Raw) | Should Be 'shared v3 (gamma edit)'
        (Get-Content -LiteralPath (Join-Path $repo 'alpha.txt') -Raw) | Should Be 'alpha only'
        Test-Path (Join-Path $repo 'beta.txt') | Should Be $false

        Invoke-PsGitCommand -CommandInput 'checkout alpha' -RepoPath $repo
        Test-Path (Join-Path $repo 'gamma.txt') | Should Be $false
        Test-Path (Join-Path $repo 'beta.txt') | Should Be $false
        (Get-Content -LiteralPath (Join-Path $repo 'alpha.txt') -Raw) | Should Be 'alpha only'
        (Get-Content -LiteralPath (Join-Path $repo 'shared.txt') -Raw) | Should Be 'shared v1'

        Invoke-PsGitCommand -CommandInput 'checkout beta' -RepoPath $repo
        Test-Path (Join-Path $repo 'alpha.txt') | Should Be $false
        (Get-Content -LiteralPath (Join-Path $repo 'beta.txt') -Raw) | Should Be 'beta only'
        (Get-Content -LiteralPath (Join-Path $repo 'shared.txt') -Raw) | Should Be 'shared v2 (beta edit)'

        # detached HEAD by raw commit sha - back to gamma's ancestor state via alpha's tip isn't
        # right; use beta's own sha again (re-resolving the exact same commit, but through the
        # "not a branch name" Resolve-PsGitId path Invoke-PsGitCommand's checkout falls back to)
        Invoke-PsGitCommand -CommandInput "checkout $($global:PsGitEdgeBetaId)" -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'beta.txt') -Raw) | Should Be 'beta only'
        Test-Path (Join-Path $repo 'alpha.txt') | Should Be $false
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitEdgeBranchRepo
            $head.Symbolic | Should Be $false
            $head.Id | Should Be $global:PsGitEdgeBetaId
        }

        Invoke-PsGitCommand -CommandInput 'checkout gamma' -RepoPath $repo
        (Get-Content -LiteralPath (Join-Path $repo 'gamma.txt') -Raw) | Should Be 'gamma only'
        (Get-Content -LiteralPath (Join-Path $repo 'alpha.txt') -Raw) | Should Be 'alpha only'
        Test-Path (Join-Path $repo 'beta.txt') | Should Be $false

        Invoke-PsGitCommand -CommandInput 'checkout alpha' -RepoPath $repo
        Test-Path (Join-Path $repo 'gamma.txt') | Should Be $false
        (Get-Content -LiteralPath (Join-Path $repo 'alpha.txt') -Raw) | Should Be 'alpha only'
        (Get-Content -LiteralPath (Join-Path $repo 'shared.txt') -Raw) | Should Be 'shared v1'
    }
}
