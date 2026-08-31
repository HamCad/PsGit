<#
.SYNOPSIS
    Exercises PsGit against real-git-authored repositories (tests/fixtures/basic.zip,
    tests/fixtures/packed.zip, tests/fixtures/refdelta.zip - built by real `git` on Linux, see
    tests/fixtures/New-Fixtures.sh) and asserts against ground truth captured from real git at
    fixture-build time (manifest.json inside each fixture).

    'basic' has only loose objects: proves PsGit correctly reads objects it did not write itself.
    'packed' was git-repacked (git repack -a -d): it has ZERO loose objects, so every read below
    goes through PsGitPackReader.ps1 / PsGitPackIndex.ps1, including resolving real ofs-delta
    chains (some up to depth 4, including delta-encoded COMMIT objects, not just blobs) - this is
    the actual "does compression/decoding match real git" validation, not a self-round-trip.
    'refdelta' is a thin pack (git pack-objects --thin + index-pack --fix-thin, the same path a
    real fetch/clone takes) covering the one pack encoding 'packed' can't produce locally: a
    genuine REF_DELTA object, plus a loose/pack boundary partway through history.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators).
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force
. (Join-Path $PSScriptRoot 'Fixture.Helpers.ps1')

# ===================================================================== fixture: basic (loose) ==
Describe 'PsGit reading a real-git repo: basic (loose objects)' {

    $fixture = Expand-PsGitTestFixture -Name 'basic'
    $global:PsGitFixtureBasicPath = $fixture.Path
    $global:PsGitFixtureBasicManifest = $fixture.Manifest

    It 'resolves HEAD to the commit real git recorded' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitFixtureBasicPath
            $head.Id | Should Be $global:PsGitFixtureBasicManifest.head_sha
        }
    }

    It 'walks the commit log matching real git, newest first' {
        InModuleScope PsGit {
            $log = @(Get-PsGitLog -RepoPath $global:PsGitFixtureBasicPath)
            $expected = @($global:PsGitFixtureBasicManifest.commits)
            $log.Count | Should Be $expected.Count
            for ($i = 0; $i -lt $expected.Count; $i++) {
                $log[$i].Id | Should Be $expected[$i].sha
                $log[$i].Message.Trim() | Should Be $expected[$i].subject
                if ($expected[$i].parents.Count -gt 0 -and $expected[$i].parents[0]) {
                    $log[$i].Parents[0] | Should Be $expected[$i].parents[0]
                }
            }
        }
    }

    It 'lists the HEAD tree matching real git (path/mode/blob id)' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitFixtureBasicPath
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $global:PsGitFixtureBasicPath -Id $head.Id).Content
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitFixtureBasicPath -TreeId $commit.Tree)
            $expected = @($global:PsGitFixtureBasicManifest.head_tree)
            $entries.Count | Should Be $expected.Count
            foreach ($exp in $expected) {
                $match = $entries | Where-Object { $_.Path -eq $exp.path }
                $match | Should Not Be $null
                $match.Id | Should Be $exp.sha
            }
        }
    }

    It 'lists both real branches with the correct current branch' {
        InModuleScope PsGit {
            $branches = @(Get-PsGitBranch -RepoPath $global:PsGitFixtureBasicPath)
            $expected = @($global:PsGitFixtureBasicManifest.branches)
            $branches.Count | Should Be $expected.Count
            ($branches | Where-Object { $_.Name -eq 'main' }).IsCurrent | Should Be $true
            ($branches | Where-Object { $_.Name -eq 'feature/thing' }) | Should Not Be $null
        }
    }

    It 'reports a clean status against the checked-out working tree (gitignore honored)' {
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitFixtureBasicPath
            @($st.Staged).Count | Should Be 0
            @($st.Unstaged).Count | Should Be 0
            # build/output.txt exists on disk but is excluded by .gitignore - must not appear untracked
            @($st.Untracked).Count | Should Be 0
        }
    }

    It 'decodes every real blob (unicode text + binary) byte-exact via the full object path' {
        InModuleScope PsGit {
            foreach ($prop in $global:PsGitFixtureBasicManifest.blob_content_b64.PSObject.Properties) {
                $sha = $prop.Name
                $expectedBytes = [Convert]::FromBase64String($prop.Value)
                $obj = Get-PsGitObject -RepoPath $global:PsGitFixtureBasicPath -Id $sha
                $obj.Content.Length | Should Be $expectedBytes.Length
                $same = $true
                for ($k = 0; $k -lt $expectedBytes.Length; $k++) { if ($obj.Content[$k] -ne $expectedBytes[$k]) { $same = $false; break } }
                $same | Should Be $true
            }
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

# ================================================================ fixture: packed (real pack) ==
Describe 'PsGit reading a real-git repo: packed (real .pack/.idx, ofs-deltas)' {

    $fixture = Expand-PsGitTestFixture -Name 'packed'
    $global:PsGitFixturePackedPath = $fixture.Path
    $global:PsGitFixturePackedManifest = $fixture.Manifest

    It 'has zero loose objects (proves reads below go through the pack, not loose fallback)' {
        $looseCount = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Path '.git\objects') -Directory |
            Where-Object { $_.Name -ne 'pack' -and $_.Name -ne 'info' } |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File }).Count
        $looseCount | Should Be 0
    }

    It 'resolves HEAD to the commit real git recorded (from the pack)' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitFixturePackedPath
            $head.Id | Should Be $global:PsGitFixturePackedManifest.head_sha
        }
    }

    It 'walks the full commit log through the pack, including delta-encoded commit objects' {
        InModuleScope PsGit {
            $log = @(Get-PsGitLog -RepoPath $global:PsGitFixturePackedPath)
            $expected = @($global:PsGitFixturePackedManifest.commits)
            $log.Count | Should Be $expected.Count
            for ($i = 0; $i -lt $expected.Count; $i++) {
                $log[$i].Id | Should Be $expected[$i].sha
                $log[$i].Message.Trim() | Should Be $expected[$i].subject
            }
        }
    }

    It 'lists the HEAD tree matching real git' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitFixturePackedPath
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $global:PsGitFixturePackedPath -Id $head.Id).Content
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitFixturePackedPath -TreeId $commit.Tree)
            $expected = @($global:PsGitFixturePackedManifest.head_tree)
            $entries.Count | Should Be $expected.Count
            foreach ($exp in $expected) {
                ($entries | Where-Object { $_.Path -eq $exp.path }).Id | Should Be $exp.sha
            }
        }
    }

    It 'has at least one real delta chain of depth 2 or more to actually exercise' {
        $deepDeltas = @($global:PsGitFixturePackedManifest.pack_delta_objects | Where-Object { $_.depth -ge 2 })
        $deepDeltas.Count | Should BeGreaterThan 0
    }

    It 'resolves every delta-encoded object (and its base) to byte-exact real-git content' {
        InModuleScope PsGit {
            foreach ($prop in $global:PsGitFixturePackedManifest.pack_delta_content_b64.PSObject.Properties) {
                $sha = $prop.Name
                $expectedBytes = [Convert]::FromBase64String($prop.Value)
                $obj = Get-PsGitObject -RepoPath $global:PsGitFixturePackedPath -Id $sha
                $obj.Content.Length | Should Be $expectedBytes.Length
                $same = $true
                for ($k = 0; $k -lt $expectedBytes.Length; $k++) { if ($obj.Content[$k] -ne $expectedBytes[$k]) { $same = $false; break } }
                $same | Should Be $true
                # and PsGit's own hash of the delta-resolved content must reproduce the requested id
                (Get-PsGitObjectId -Type $obj.Type -Content $obj.Content) | Should Be $sha
            }
        }
    }

    It 'reports a clean status against the checked-out working tree' {
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitFixturePackedPath
            (@($st.Staged).Count + @($st.Unstaged).Count + @($st.Untracked).Count) | Should Be 0
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}

# ============================================================ fixture: refdelta (ref-delta) ==
Describe 'PsGit reading a real-git repo: refdelta (real .pack/.idx, ref-delta)' {
    <#
    'packed' above only exercises ofs-delta, since `git repack -a -d` on a local repo never
    produces ref-deltas. This fixture is a thin pack (built the way a real `git fetch`/`clone`
    would: `git pack-objects --thin` + `index-pack --fix-thin`, see tests/fixtures/New-Fixtures.sh)
    with its base commit's commit+tree left loose and everything else - including one genuine
    ref-delta blob - packed, so it also covers the mixed loose+pack case of walking history back
    past the pack boundary.
    #>

    $fixture = Expand-PsGitTestFixture -Name 'refdelta'
    $global:PsGitFixtureRefDeltaPath = $fixture.Path
    $global:PsGitFixtureRefDeltaManifest = $fixture.Manifest

    It 'has exactly one delta object, and it is really encoded as ref-delta (not ofs-delta)' {
        $deltas = @($global:PsGitFixtureRefDeltaManifest.pack_delta_objects)
        $deltas.Count | Should Be 1
        $deltas[0].encoding | Should Be 'ref-delta'
    }

    It 'has no loose copy of the delta object or its base (proves reads go through the pack)' {
        foreach ($sha in @($global:PsGitFixtureRefDeltaManifest.pack_delta_objects[0].sha, $global:PsGitFixtureRefDeltaManifest.pack_delta_objects[0].base)) {
            $loosePath = Join-Path $fixture.Path (".git\objects\{0}\{1}" -f $sha.Substring(0, 2), $sha.Substring(2))
            (Test-Path -LiteralPath $loosePath) | Should Be $false
        }
    }

    It 'resolves HEAD to the commit real git recorded' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitFixtureRefDeltaPath
            $head.Id | Should Be $global:PsGitFixtureRefDeltaManifest.head_sha
        }
    }

    It 'walks the commit log across the loose/pack boundary' {
        InModuleScope PsGit {
            $log = @(Get-PsGitLog -RepoPath $global:PsGitFixtureRefDeltaPath)
            $expected = @($global:PsGitFixtureRefDeltaManifest.commits)
            $log.Count | Should Be $expected.Count
            for ($i = 0; $i -lt $expected.Count; $i++) {
                $log[$i].Id | Should Be $expected[$i].sha
                $log[$i].Message.Trim() | Should Be $expected[$i].subject
            }
        }
    }

    It 'lists the HEAD tree matching real git' {
        InModuleScope PsGit {
            $head = Get-PsGitHead -RepoPath $global:PsGitFixtureRefDeltaPath
            $commit = ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $global:PsGitFixtureRefDeltaPath -Id $head.Id).Content
            $entries = @(Expand-PsGitTree -RepoPath $global:PsGitFixtureRefDeltaPath -TreeId $commit.Tree)
            $expected = @($global:PsGitFixtureRefDeltaManifest.head_tree)
            $entries.Count | Should Be $expected.Count
            foreach ($exp in $expected) {
                ($entries | Where-Object { $_.Path -eq $exp.path }).Id | Should Be $exp.sha
            }
        }
    }

    It 'resolves the ref-delta blob (and its base) to byte-exact real-git content' {
        InModuleScope PsGit {
            foreach ($prop in $global:PsGitFixtureRefDeltaManifest.pack_delta_content_b64.PSObject.Properties) {
                $sha = $prop.Name
                $expectedBytes = [Convert]::FromBase64String($prop.Value)
                $obj = Get-PsGitObject -RepoPath $global:PsGitFixtureRefDeltaPath -Id $sha
                $obj.Content.Length | Should Be $expectedBytes.Length
                $same = $true
                for ($k = 0; $k -lt $expectedBytes.Length; $k++) { if ($obj.Content[$k] -ne $expectedBytes[$k]) { $same = $false; break } }
                $same | Should Be $true
                (Get-PsGitObjectId -Type $obj.Type -Content $obj.Content) | Should Be $sha
            }
        }
    }

    It 'reports a clean status against the checked-out working tree' {
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitFixtureRefDeltaPath
            (@($st.Staged).Count + @($st.Unstaged).Count + @($st.Untracked).Count) | Should Be 0
        }
    }

    Remove-PsGitTestFixture -Path $fixture.Path
}
