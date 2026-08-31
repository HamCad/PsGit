<#
.SYNOPSIS
    Edge cases for the ref-name validation added for Gitea issue #14 (Windows reserved device
    names silently no-op a branch create) that tests/PsGit.Adversarial.Tests.ps1 does not already
    exercise.
.DESCRIPTION
    The adversarial suite's repro only proves `New-PsGitBranch -Name 'con'` either throws or
    actually persists. This file is scoped to what's left:

      - Test-PsGitSafeRefName itself: ordinary names still pass (no regression), every reserved
        device name is caught case-insensitively, a reserved name with an extension ('con.txt')
        and as a nested path segment ('feature/con') are both caught (Windows reserves the device
        name before the extension, and a path component collides with the device regardless of
        depth), and each of git's own check-ref-format character/shape rules (forbidden
        characters, a control character, trailing '.lock', a trailing dot, a leading-dot
        component, consecutive dots, '@{', the bare name '@', an empty name, an empty path
        segment) is rejected individually.
      - New-PsGitBranch end-to-end: every reserved device name throws and never creates a ref
        file (the adversarial suite only tries 'con'), an invalid character throws the same way,
        and an ordinary branch name still creates normally - proving the new validation didn't
        break the working case.
      - Set-PsGitRef's own write-verification backstop: calling it directly with a reserved
        device name (bypassing New-PsGitBranch's Assert-PsGitSafeRefName entirely) still throws,
        because Set-PsGitRef re-checks the file actually landed on disk after WriteAllText - the
        defense-in-depth layer the issue asked for, independent of the name-validation layer.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitRefSafetyRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    'x' | Set-Content -LiteralPath (Join-Path $repo 'x.txt') -NoNewline -Encoding UTF8
    Add-PsGitFile -RepoPath $repo -Path 'x.txt'
    $null = New-PsGitCommit -RepoPath $repo -Message 'x'
    return $repo
}

Describe 'Test-PsGitSafeRefName: git ref-format rules and Windows device names' {

    It 'accepts ordinary branch names' {
        InModuleScope PsGit {
            foreach ($name in @('main', 'feature/x', 'release-1.0', 'a.b-c_d')) {
                Test-PsGitSafeRefName -Name $name | Should Be $true
            }
        }
    }

    It 'rejects every reserved device name, case-insensitively' {
        InModuleScope PsGit {
            $names = @('con', 'CON', 'Con', 'prn', 'aux', 'nul', 'com1', 'COM9', 'lpt1', 'LPT9')
            foreach ($name in $names) {
                Test-PsGitSafeRefName -Name $name | Should Be $false
            }
        }
    }

    It 'rejects a reserved device name with an extension' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'con.txt' | Should Be $false
        }
    }

    It 'rejects a reserved device name as a nested path segment' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'feature/con' | Should Be $false
        }
    }

    It 'rejects each character git forbids in a ref name' {
        InModuleScope PsGit {
            foreach ($ch in @(' ', '~', '^', ':', '?', '*', '[', '\')) {
                Test-PsGitSafeRefName -Name "feature${ch}branch" | Should Be $false
            }
        }
    }

    It 'rejects a name containing an ASCII control character' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name "feature$([char]7)branch" | Should Be $false
        }
    }

    It 'rejects a name ending in ".lock"' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'feature.lock' | Should Be $false
        }
    }

    It 'rejects a name ending in a trailing dot' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'feature.' | Should Be $false
        }
    }

    It 'rejects a name with a leading-dot path component' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name '.hidden' | Should Be $false
        }
    }

    It 'rejects a name containing consecutive dots' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'feature..branch' | Should Be $false
        }
    }

    It 'rejects a name containing "@{"' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'feature@{0}' | Should Be $false
        }
    }

    It 'rejects the bare name "@"' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name '@' | Should Be $false
        }
    }

    It 'rejects an empty name' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name '' | Should Be $false
        }
    }

    It 'rejects a name with an empty path segment' {
        InModuleScope PsGit {
            Test-PsGitSafeRefName -Name 'feature//branch' | Should Be $false
        }
    }
}

Describe 'New-PsGitBranch: reserved device names are rejected end-to-end' {

    It 'throws for every reserved device name and never creates a ref file' {
        $repo = New-PsGitRefSafetyRepo 'ref-devnames'
        foreach ($name in @('con', 'prn', 'aux', 'nul', 'com1', 'lpt1')) {
            $threw = $false
            try { New-PsGitBranch -RepoPath $repo -Name $name } catch { $threw = $true }
            $threw | Should Be $true
            (Test-Path (Join-Path $repo ".git\refs\heads\$name")) | Should Be $false
        }
    }

    It 'throws for a name containing a forbidden character and never creates a ref file' {
        $repo = New-PsGitRefSafetyRepo 'ref-badchar'
        $threw = $false
        try { New-PsGitBranch -RepoPath $repo -Name 'feat*ure' } catch { $threw = $true }
        $threw | Should Be $true
        (Test-Path (Join-Path $repo '.git\refs\heads\feat*ure')) | Should Be $false
    }

    It 'still creates an ordinary branch normally (no regression)' {
        $repo = New-PsGitRefSafetyRepo 'ref-ordinary'
        New-PsGitBranch -RepoPath $repo -Name 'feature/widget'
        (Test-Path (Join-Path $repo '.git\refs\heads\feature\widget')) | Should Be $true
    }
}

Describe 'Set-PsGitRef: write-verification backstop is independent of Assert-PsGitSafeRefName' {

    It 'throws if asked to write a ref named after a reserved device, even called directly' {
        $repo = New-PsGitRefSafetyRepo 'ref-backstop'
        $global:PsGitRefSafetyRepo = $repo
        $threw = $false
        try {
            InModuleScope PsGit {
                Set-PsGitRef -RepoPath $global:PsGitRefSafetyRepo -Name 'refs/heads/con' -Id ('0' * 40)
            }
        } catch { $threw = $true }
        $threw | Should Be $true
    }
}
