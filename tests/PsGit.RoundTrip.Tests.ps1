<#
.SYNOPSIS
    Self-consistency tests: PsGit writing and reading its own data (init/add/status/commit/log/
    diff/branch/checkout), independent of any real-git fixture.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators).
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

Describe 'PsGit round-trip: init/add/status/commit/log/diff/branch/checkout' {

    $repo = Join-Path $TestDrive 'roundtrip-repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    $global:PsGitRoundTripRepo = $repo

    It 'initializes a repo' {
        Invoke-PsGitCommand -CommandInput 'init' -RepoPath $repo
        Test-Path (Join-Path $repo '.git\HEAD') | Should Be $true
    }

    "Hello World" | Set-Content -LiteralPath (Join-Path $repo 'readme.txt') -Encoding UTF8 -NoNewline
    "line1`nline2`nline3" | Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Encoding UTF8 -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $repo 'nested\dir') -Force | Out-Null
    "nested content" | Set-Content -LiteralPath (Join-Path $repo 'nested\dir\deep.txt') -Encoding UTF8 -NoNewline

    It 'status shows untracked files before add' {
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitRoundTripRepo
            @($st.Untracked).Count | Should Be 3
            @($st.Staged).Count | Should Be 0
        }
    }

    It 'add . stages every untracked file' {
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitRoundTripRepo
            @($st.Staged).Count | Should Be 3
            @($st.Untracked).Count | Should Be 0
        }
    }

    It 'commits the staged files' {
        Invoke-PsGitCommand -CommandInput 'commit -m "initial commit"' -RepoPath $repo
        InModuleScope PsGit {
            $log = @(Get-PsGitLog -RepoPath $global:PsGitRoundTripRepo)
            $log.Count | Should Be 1
            $log[0].Message.Trim() | Should Be 'initial commit'
        }
    }

    It 'status is clean immediately after commit' {
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitRoundTripRepo
            (@($st.Staged).Count + @($st.Unstaged).Count + @($st.Untracked).Count) | Should Be 0
        }
    }

    It 'modifying a tracked file shows up as unstaged' {
        "line1`nline2-CHANGED`nline3`nline4" | Set-Content -LiteralPath (Join-Path $repo 'file.txt') -Encoding UTF8 -NoNewline
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitRoundTripRepo
            @($st.Unstaged).Count | Should Be 1
            $st.Unstaged[0].Path | Should Be 'file.txt'
        }
    }

    It 'diff reports the change as add/remove hunk lines' {
        InModuleScope PsGit {
            $diff = Get-PsGitDiff -RepoPath $global:PsGitRoundTripRepo -Path 'file.txt'
            $diff | Should Match '-line2'
            $diff | Should Match '\+line2-CHANGED'
            $diff | Should Match '\+line4'
        }
    }

    It 'commits the second change and log grows' {
        Invoke-PsGitCommand -CommandInput 'add .' -RepoPath $repo
        Invoke-PsGitCommand -CommandInput 'commit -m "modify file.txt"' -RepoPath $repo
        InModuleScope PsGit {
            $log = @(Get-PsGitLog -RepoPath $global:PsGitRoundTripRepo)
            $log.Count | Should Be 2
            $log[0].Message.Trim() | Should Be 'modify file.txt'
            $log[1].Message.Trim() | Should Be 'initial commit'
            $log[0].Parents | Should Be $log[1].Id
        }
    }

    It 'creates a branch pointing at HEAD' {
        Invoke-PsGitCommand -CommandInput 'branch new feature-x' -RepoPath $repo
        InModuleScope PsGit {
            $branches = @(Get-PsGitBranch -RepoPath $global:PsGitRoundTripRepo)
            ($branches | Where-Object { $_.Name -eq 'feature-x' }) | Should Not Be $null
            ($branches | Where-Object { $_.Name -eq 'main' -or $_.Name -eq 'master' }).IsCurrent | Should Be $true
        }
    }

    It 'checkout switches the current branch' {
        Invoke-PsGitCommand -CommandInput 'checkout feature-x' -RepoPath $repo
        InModuleScope PsGit {
            $branches = @(Get-PsGitBranch -RepoPath $global:PsGitRoundTripRepo)
            ($branches | Where-Object { $_.Name -eq 'feature-x' }).IsCurrent | Should Be $true
        }
    }

    It 'deleting a tracked file shows as deleted once staged' {
        Remove-Item -LiteralPath (Join-Path $repo 'nested\dir\deep.txt') -Force
        InModuleScope PsGit {
            $st = Get-PsGitStatus -RepoPath $global:PsGitRoundTripRepo
            ($st.Unstaged | Where-Object { $_.Path -eq 'nested/dir/deep.txt' }).State | Should Be 'deleted'
        }
    }

    It 'round-trips a binary file byte-for-byte through the object store' {
        InModuleScope PsGit {
            $rng = New-Object System.Random(99)
            $bytes = New-Object byte[] 512
            $rng.NextBytes($bytes)
            $id = Write-PsGitObject -RepoPath $global:PsGitRoundTripRepo -Type 'blob' -Content $bytes
            $obj = Get-PsGitObject -RepoPath $global:PsGitRoundTripRepo -Id $id
            $obj.Type | Should Be 'blob'
            $obj.Content.Length | Should Be $bytes.Length
            $same = $true
            for ($k = 0; $k -lt $bytes.Length; $k++) { if ($obj.Content[$k] -ne $bytes[$k]) { $same = $false; break } }
            $same | Should Be $true
        }
    }
}

Describe 'PsGit round-trip: index (Read-PsGitIndex / Write-PsGitIndex)' {

    $repo = Join-Path $TestDrive 'index-repo'
    New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
    $global:PsGitIndexRepo = $repo

    It 'reads an empty/missing index as zero entries' {
        InModuleScope PsGit {
            @(Read-PsGitIndex -RepoPath $global:PsGitIndexRepo).Count | Should Be 0
        }
    }

    It 'round-trips a set of entries byte-exact, sorted by path, across the 8-byte alignment boundary' {
        InModuleScope PsGit {
            # path lengths chosen so contentLen (62 + path bytes) lands on either side of a
            # multiple of 8, exercising every possible pad amount (1..8 NUL bytes) at least once
            $entries = @(
                [pscustomobject]@{ Path = 'z.txt';                     Mode = '100644'; Id = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'; Size = 0 }
                [pscustomobject]@{ Path = 'a';                         Mode = '100644'; Id = 'ce013625030ba8dba906f756967f9e9ca394464a'; Size = 6 }
                [pscustomobject]@{ Path = 'src/main.ps1';              Mode = '100755'; Id = '1234567890abcdef1234567890abcdef12345678'; Size = 1024 }
                [pscustomobject]@{ Path = 'nested/dir/deep/file12.txt'; Mode = '100644'; Id = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'; Size = 42 }
                [pscustomobject]@{ Path = 'nested/dir/deep/file123.txt'; Mode = '100644'; Id = 'fedcba0987654321fedcba0987654321fedcba09'; Size = 43 }
            )
            Write-PsGitIndex -RepoPath $global:PsGitIndexRepo -Entries $entries

            $readBack = @(Read-PsGitIndex -RepoPath $global:PsGitIndexRepo)
            $readBack.Count | Should Be $entries.Count

            $sortedExpected = @($entries | Sort-Object -Property Path)
            for ($i = 0; $i -lt $sortedExpected.Count; $i++) {
                $readBack[$i].Path | Should Be $sortedExpected[$i].Path
                $readBack[$i].Mode | Should Be $sortedExpected[$i].Mode
                $readBack[$i].Id | Should Be $sortedExpected[$i].Id
                $readBack[$i].Size | Should Be $sortedExpected[$i].Size
            }
        }
    }

    It 'round-trips a unicode path byte-exact' {
        InModuleScope PsGit {
            $entries = @([pscustomobject]@{ Path = 'café/résumé.txt'; Mode = '100644'; Id = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'; Size = 0 })
            Write-PsGitIndex -RepoPath $global:PsGitIndexRepo -Entries $entries
            $readBack = @(Read-PsGitIndex -RepoPath $global:PsGitIndexRepo)
            $readBack.Count | Should Be 1
            $readBack[0].Path | Should Be 'café/résumé.txt'
        }
    }

    It 'writes zero entries for an empty entry list' {
        InModuleScope PsGit {
            Write-PsGitIndex -RepoPath $global:PsGitIndexRepo -Entries @()
            @(Read-PsGitIndex -RepoPath $global:PsGitIndexRepo).Count | Should Be 0
        }
    }
}
