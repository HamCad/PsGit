<#
.SYNOPSIS
    Edge cases for the tree/index path validation added for Gitea issues #6 (".git" overwrite) and
    #7 ("../" traversal) that tests/PsGit.Adversarial.Tests.ps1 does not already exercise.
.DESCRIPTION
    PsGit.Adversarial.Tests.ps1 already covers the two headline repros (a leading '../' entry and a
    '.git/config' entry). This file is scoped to the fix's remaining edge cases, called out in the
    issues themselves but not asserted anywhere yet: a bare '.git' entry with no subpath, the
    Windows 8.3 short-name alias 'GIT~1', a '..' segment that isn't the first path component, an
    empty ('//') segment, and staging the traversal directly through the public Add-PsGitFile
    entry point rather than only the low-level object/tree APIs.
.NOTES
    PowerShell 5.1+ / Pester 3.4 syntax ('Should Be', no dash operators), matching the existing
    suite's convention.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force

function New-PsGitPathSafetyRepo {
    param([Parameter(Mandatory)][string]$Name)
    $repo = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Initialize-PsGitRepo -RepoPath $repo
    return $repo
}

Describe 'PathSafety: unsafe tree paths are rejected regardless of shape' {

    It 'a bare ".git" entry (no subpath) is rejected' {
        $repo = New-PsGitPathSafetyRepo 'ps-bare-dotgit'
        $global:PsGitPSRepo = $repo
        $threw = $false
        try {
            InModuleScope PsGit {
                $blobId = Write-PsGitObject -RepoPath $global:PsGitPSRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('PWNED'))
                $entries = @([pscustomobject]@{ Path = '.git'; Mode = '100644'; Id = $blobId; Size = 5 })
                $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitPSRepo -Entries $entries
                Restore-PsGitTree -RepoPath $global:PsGitPSRepo -Id $treeId
            }
        } catch { $threw = $true }
        $threw | Should Be $true
    }

    It 'the NTFS 8.3 short-name alias "GIT~1" is rejected like ".git"' {
        $repo = New-PsGitPathSafetyRepo 'ps-shortname'
        $global:PsGitPSRepo = $repo
        $threw = $false
        try {
            InModuleScope PsGit {
                $blobId = Write-PsGitObject -RepoPath $global:PsGitPSRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('PWNED'))
                $entries = @([pscustomobject]@{ Path = 'GIT~1/config'; Mode = '100644'; Id = $blobId; Size = 5 })
                $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitPSRepo -Entries $entries
                Restore-PsGitTree -RepoPath $global:PsGitPSRepo -Id $treeId
            }
        } catch { $threw = $true }
        $threw | Should Be $true
    }

    It 'a ".." segment that is not the first path component is rejected' {
        $repo = New-PsGitPathSafetyRepo 'ps-mid-traversal'
        $outside = Join-Path (Split-Path -Parent $repo) 'MID_TRAVERSAL_SENTINEL.txt'
        'do not touch me' | Set-Content -LiteralPath $outside -NoNewline -Encoding UTF8
        $global:PsGitPSRepo = $repo
        $global:PsGitPSRel = 'src/../../' + (Split-Path -Leaf $outside)

        $threw = $false
        try {
            InModuleScope PsGit {
                $blobId = Write-PsGitObject -RepoPath $global:PsGitPSRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('PWNED'))
                $entries = @([pscustomobject]@{ Path = $global:PsGitPSRel; Mode = '100644'; Id = $blobId; Size = 5 })
                $treeId = ConvertTo-PsGitTree -RepoPath $global:PsGitPSRepo -Entries $entries
                Restore-PsGitTree -RepoPath $global:PsGitPSRepo -Id $treeId
            }
        } catch { $threw = $true }

        $victimContent = Get-Content -LiteralPath $outside -Raw
        Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue
        ($threw -or $victimContent -notmatch 'PWNED') | Should Be $true
    }

    It 'an empty path segment ("a//b.txt") is rejected' {
        $repo = New-PsGitPathSafetyRepo 'ps-empty-segment'
        $global:PsGitPSRepo = $repo
        $threw = $false
        try {
            InModuleScope PsGit {
                $blobId = Write-PsGitObject -RepoPath $global:PsGitPSRepo -Type 'blob' -Content ([System.Text.Encoding]::UTF8.GetBytes('x'))
                $entries = @([pscustomobject]@{ Path = 'a//b.txt'; Mode = '100644'; Id = $blobId; Size = 1 })
                ConvertTo-PsGitTree -RepoPath $global:PsGitPSRepo -Entries $entries
            }
        } catch { $threw = $true }
        $threw | Should Be $true
    }

    It 'Add-PsGitFile refuses to stage a path containing ".." rather than filtering it only at checkout' {
        $repo = New-PsGitPathSafetyRepo 'ps-stage-traversal'
        $outsideDir = Join-Path (Split-Path -Parent $repo) 'ps-stage-traversal-sibling'
        New-Item -ItemType Directory -Path $outsideDir -Force | Out-Null
        'sibling content' | Set-Content -LiteralPath (Join-Path $outsideDir 'sibling.txt') -NoNewline -Encoding UTF8

        $threw = $false
        try {
            Add-PsGitFile -RepoPath $repo -Path '../ps-stage-traversal-sibling/sibling.txt'
        } catch { $threw = $true }
        $threw | Should Be $true
    }
}
