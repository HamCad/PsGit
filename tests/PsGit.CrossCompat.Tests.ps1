<#
.SYNOPSIS
    Exercises PsGit against tests/fixtures/crosscompat.zip - a real-git repo (built by real `git`
    on Linux, see tests/fixtures/New-CrossCompatFixture.sh) purpose-built to probe git edge cases
    the existing fixture suite (PsGit.Fixtures.Tests.ps1's basic/packed/refdelta) never touches:

      - a real tree-entry sort-order collision (a directory name vs. file names that share its
        prefix) - proves ConvertTo-PsGitTree's sort comparer produces the exact byte-identical
        tree object real git does, not just "the right set of entries in some order"
      - a submodule/gitlink entry (mode 160000) at HEAD
      - two paths differing only by case coexisting in one tree (legal git data from a
        case-sensitive filesystem; PowerShell's case-INSENSITIVE @{} hashtable literal is a real
        hazard against data shaped like this - see PsGit.EdgeCases.Tests.ps1 for the write-side
        half of this investigation)
      - a path containing a literal backslash byte (legal on Linux/git; PsGit's own
        Assert-PsGitSafeTreePath, added for Gitea #6/#7, is supposed to reject it)
      - paths matching Windows reserved device names (con, nul.txt, ...) - legal on Linux; the
        live checkout hazard this creates on Windows is exercised in PsGit.EdgeCases.Tests.ps1,
        this file only proves PsGit can read the tree data safely
      - every branch (main + 3 history-only branches) resolvable ONLY through a real
        `git pack-refs --all`-produced packed-refs file, zero loose refs/heads/* files present

    The three "history-only" branches (history/case-clash, history/backslash-path,
    history/reserved-names) are never checked out - not by real git when the fixture was built,
    and not by any test below. Their trees are read purely through the object graph
    (Expand-PsGitTree / Get-PsGitObject against a commit sha pulled from the manifest), because
    a physical checkout of paths like 'Config.txt'+'config.txt' or 'con' onto Windows/NTFS would
    hit filesystem-level collisions of its own, unrelated to whatever PsGit does or doesn't do -
    see New-CrossCompatFixture.sh's comments for why these are built via plumbing against a
    scratch index instead of a normal working-tree commit.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force
. (Join-Path $PSScriptRoot 'Fixture.Helpers.ps1')

Describe 'CrossCompat: baseline HEAD and packed-refs-only branch resolution' {

    $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
    $global:PsGitCCPath = $fixture.Path
    $global:PsGitCCManifest = $fixture.Manifest

    It 'has zero loose refs/heads/* files (every branch below is resolved purely via packed-refs)' {
        $looseDir = Join-Path $fixture.Path '.git\refs\heads'
        $looseFiles = @()
        if (Test-Path -LiteralPath $looseDir) {
            $looseFiles = @(Get-ChildItem -LiteralPath $looseDir -Recurse -File -ErrorAction SilentlyContinue)
        }
        $looseFiles.Count | Should Be 0
        $global:PsGitCCManifest.packed_refs_only | Should Be $true
    }

    It 'resolves HEAD to the commit real git recorded' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitCCPath
            $head.Id | Should Be $global:PsGitCCManifest.head_sha
        }
    }

    It 'lists all four branches (main + 3 history-only) with correct ids, sourced only from packed-refs' {
        InModuleScope PsGit {
            $branches = @(Get-PsGitBranch -RepoPath $global:PsGitCCPath)
            $expected = @($global:PsGitCCManifest.branches)
            $branches.Count | Should Be $expected.Count
            foreach ($exp in $expected) {
                $match = $branches | Where-Object { $_.Name -eq $exp.name }
                $match | Should Not Be $null
                $match.Id | Should Be $exp.sha
            }
            ($branches | Where-Object { $_.Name -eq 'main' }).IsCurrent | Should Be $true
        }
    }

    It 'resolves each history-only branch ref to its real-git sha via Get-PsGitRef (packed-refs parsing)' {
        InModuleScope PsGit {
            foreach ($name in @('history/case-clash', 'history/backslash-path', 'history/reserved-names')) {
                $expected = ($global:PsGitCCManifest.branches | Where-Object { $_.name -eq $name }).sha
                (Get-PsGitRef -RepoPath $global:PsGitCCPath -Name "refs/heads/$name") | Should Be $expected
            }
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

Describe 'CrossCompat: real tree-entry sort-order collision (directory vs. file name prefix)' {
    <#
    Git sorts tree entries as if every directory name carried a trailing '/' for comparison. A
    naive lexicographic sort of the bare names would put 'lib' (the directory) before
    'lib-old.txt' and 'lib.txt' (shorter prefix sorts first); real git's actual order is
    lib-old.txt, lib.txt, lib/ - '-' (0x2D) and '.' (0x2E) both sort before '/' (0x2F), so the
    bare directory name sorts LAST, not first. This is the classic case a from-scratch tree
    writer gets backwards. tests/fixtures/New-CrossCompatFixture.sh built exactly this shape at
    HEAD; tree_sort_paths in the manifest is real git's own ls-tree order for it.
    #>

    $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
    $global:PsGitCCSortPath = $fixture.Path
    $global:PsGitCCSortManifest = $fixture.Manifest

    It 'Expand-PsGitTree returns the three colliding entries in real git''s exact order' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitCCSortPath
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $global:PsGitCCSortPath -Id $head.Id).Content
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitCCSortPath -TreeId $commit.Tree)
            $ordered = @($entries | Where-Object { $_.Path -in @('lib-old.txt', 'lib.txt', 'lib/inner.txt') } | Select-Object -ExpandProperty Path)
            # Expand-PsGitTree recurses depth-first per directory entry in TREE order, so the
            # order it yields these three in reflects ConvertTo-PsGitTree's read-back sort - this
            # is read-path confirmation, the write-path proof is the next It block.
            $ordered.Count | Should Be 3
            for ($i = 0; $i -lt 3; $i++) { $ordered[$i] | Should Be $global:PsGitCCSortManifest.tree_sort_paths[$i] }
        }
    }

    It 'ConvertTo-PsGitTree reproduces the EXACT SAME tree object id real git computed for this entry set' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitCCSortPath
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $global:PsGitCCSortPath -Id $head.Id).Content
            $realTreeId = $commit.Tree
            $flat = @(Expand-PsGitTree -RepoPath $global:PsGitCCSortPath -TreeId $realTreeId)
            # Rebuild the identical tree from PsGit's own flattened entries and re-hash it: if
            # ConvertTo-PsGitTree's sort comparer (the IsDir + '/' trick) is even slightly off
            # from real git's, this reproduces a DIFFERENT sha even though every individual blob
            # id matches - proving byte-exact object-format compatibility, not just content parity.
            $rebuiltTreeId = ConvertTo-PsGitTree -RepoPath $global:PsGitCCSortPath -Entries $flat
            $rebuiltTreeId | Should Be $realTreeId
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

Describe 'CrossCompat: submodule/gitlink entry (mode 160000) at HEAD' {

    $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
    $global:PsGitCCGitlinkPath = $fixture.Path
    $global:PsGitCCGitlinkManifest = $fixture.Manifest

    It 'Expand-PsGitTree includes the gitlink as a flat entry without trying to read/expand it as a tree' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitCCGitlinkPath
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $global:PsGitCCGitlinkPath -Id $head.Id).Content
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitCCGitlinkPath -TreeId $commit.Tree)
            $gitlink = $entries | Where-Object { $_.Path -eq $global:PsGitCCGitlinkManifest.gitlink.path }
            $gitlink | Should Not Be $null
            $gitlink.Mode | Should Be $global:PsGitCCGitlinkManifest.gitlink.mode
            $gitlink.Id | Should Be $global:PsGitCCGitlinkManifest.gitlink.sha
        }
    }

    It 'restoring HEAD (which includes the gitlink) does not corrupt the other real tracked files, whatever it does with the gitlink itself' {
        $before = Get-Content -LiteralPath (Join-Path $fixture.Path 'readme.md') -Raw
        $beforeLib = Get-Content -LiteralPath (Join-Path $fixture.Path 'lib.txt') -Raw
        $threw = $false
        $errMsg = $null
        try {
            InModuleScope PsGit {
                Restore-PsGitTree -RepoPath $global:PsGitCCGitlinkPath -Id $global:PsGitCCGitlinkManifest.head_sha -Force
            }
        } catch { $threw = $true; $errMsg = $_.Exception.Message }

        (Get-Content -LiteralPath (Join-Path $fixture.Path 'readme.md') -Raw) | Should Be $before
        (Get-Content -LiteralPath (Join-Path $fixture.Path 'lib.txt') -Raw) | Should Be $beforeLib

        # Informational, not asserted as pass/fail either way: PsGit has no submodule support, so
        # Restore-PsGitTree refuses a gitlink entry (mode 160000) with a clear error naming the
        # path/mode/commit (closes #21 - it used to throw a bare "Git object not found: '<sha>'"
        # from trying to read the gitlink's commit id as a blob). This assertion documents
        # whichever behavior is currently true without being a red herring if a future fix makes
        # it skip the entry gracefully instead.
        if ($threw) { Write-Host "  (gitlink restore threw: $errMsg)" -ForegroundColor DarkGray }
        else { Write-Host '  (gitlink restore completed without throwing)' -ForegroundColor DarkGray }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

Describe 'CrossCompat: case-clash paths coexisting in one real-git tree (history/case-clash, object-graph only)' {
    <#
    Config.txt and config.txt are two DISTINCT blobs in the same real-git tree (perfectly legal
    on the ext4 filesystem the fixture was built on). This is the read-side half of the
    hashtable-case-insensitivity investigation - PsGit.EdgeCases.Tests.ps1 covers the write side
    (ConvertTo-PsGitTree / Get-PsGitStatus / Add-PsGitFile built from scratch, no fixture needed).
    Deliberately never checked out - see this file's header comment and
    New-CrossCompatFixture.sh for why.
    #>

    $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
    $global:PsGitCCCasePath = $fixture.Path
    $global:PsGitCCCaseManifest = $fixture.Manifest

    It 'Expand-PsGitTree returns BOTH case-variant paths as distinct entries with distinct, correct blob ids' {
        InModuleScope PsGit {
            $section = $global:PsGitCCCaseManifest.case_clash
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitCCCasePath -TreeId $section.tree)
            $entries.Count | Should Be $section.entries.Count
            foreach ($exp in $section.entries) {
                $match = @($entries | Where-Object { $_.Path -ceq $exp.path })
                $match.Count | Should Be 1
                $match[0].Id | Should Be $exp.sha
            }
        }
    }

    It 'reads each case-variant blob''s content byte-exact and distinctly (not one overwriting the other)' {
        InModuleScope PsGit {
            $section = $global:PsGitCCCaseManifest.case_clash
            foreach ($prop in $section.blob_content_b64.PSObject.Properties) {
                $sha = $prop.Name
                $expectedBytes = [Convert]::FromBase64String($prop.Value)
                $obj = Get-PsGitObject -RepoPath $global:PsGitCCCasePath -Id $sha
                $obj.Content.Length | Should Be $expectedBytes.Length
                $same = $true
                for ($k = 0; $k -lt $expectedBytes.Length; $k++) { if ($obj.Content[$k] -ne $expectedBytes[$k]) { $same = $false; break } }
                $same | Should Be $true
            }
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

Describe 'CrossCompat: a literal backslash byte in a path (history/backslash-path, object-graph only)' {
    <#
    A filename byte sequence that's perfectly legal on Linux/git (the fixture's ext4 filesystem
    allows it directly). PsGit's Assert-PsGitSafeTreePath (Private/PsGitPathSafety.ps1, added for
    Gitea #6/#7) is supposed to reject any tree path containing '\', since Windows treats it as
    an extra path separator. This confirms that defense actually fires against genuine real-git
    data, not just the synthetic PWNED-style attacks PsGit.Adversarial.Tests.ps1 constructs by
    hand.
    #>

    $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
    $global:PsGitCCBackslashPath = $fixture.Path
    $global:PsGitCCBackslashManifest = $fixture.Manifest

    It 'Expand-PsGitTree refuses to expand a real-git tree containing a backslash-bearing path' {
        InModuleScope PsGit {
            $treeId = $global:PsGitCCBackslashManifest.backslash_path.tree
            $repoPath = $global:PsGitCCBackslashPath
            { Expand-PsGitTree -RepoPath $repoPath -TreeId $treeId } | Should Throw
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

Describe 'CrossCompat: Windows reserved device-name paths (history/reserved-names, object-graph only)' {
    <#
    con, nul.txt, sub/lpt1.log: ordinary filenames on the Linux machine that authored this
    history. PsGit's Assert-PsGitSafeTreePath has NO reserved-device-name check at all (unlike
    Assert-PsGitSafeRefName, which gained one for branch names in Gitea #14) - so reading this
    tree structurally should succeed cleanly. The actual hazard is downstream, at checkout time
    (Restore-PsGitTree writing the file to disk) - that live exploit is in
    PsGit.EdgeCases.Tests.ps1, since attempting it against this fixture's own extracted copy
    would collide with the same device names at the ZIP-EXTRACTION layer on Windows, before
    PsGit ever runs.
    #>

    $fixture = Expand-PsGitTestFixture -Name 'crosscompat'
    $global:PsGitCCDevPath = $fixture.Path
    $global:PsGitCCDevManifest = $fixture.Manifest

    It 'Expand-PsGitTree reads all three reserved-device-name paths without throwing' {
        InModuleScope PsGit {
            # An uncaught exception here fails the It block on its own (Pester's default
            # behavior) - no separate Should-Not-Throw wrapper needed, which also avoids that
            # wrapper's scriptblock running in a child scope where an $entries assignment
            # wouldn't survive to the next line.
            $section = $global:PsGitCCDevManifest.reserved_names
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitCCDevPath -TreeId $section.tree)
            $entries.Count | Should Be $section.entries.Count
        }
    }

    It 'each reserved-device-name blob reads back byte-exact' {
        InModuleScope PsGit {
            $section = $global:PsGitCCDevManifest.reserved_names
            foreach ($prop in $section.blob_content_b64.PSObject.Properties) {
                $sha = $prop.Name
                $expectedBytes = [Convert]::FromBase64String($prop.Value)
                $obj = Get-PsGitObject -RepoPath $global:PsGitCCDevPath -Id $sha
                $obj.Content.Length | Should Be $expectedBytes.Length
                $same = $true
                for ($k = 0; $k -lt $expectedBytes.Length; $k++) { if ($obj.Content[$k] -ne $expectedBytes[$k]) { $same = $false; break } }
                $same | Should Be $true
            }
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}
