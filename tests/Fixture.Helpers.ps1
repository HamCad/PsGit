<#
.SYNOPSIS
    Test-only helper: extract a real-git fixture (tests/fixtures/<name>.zip) to a scratch
    directory and load its manifest.json (ground truth captured from real `git` at fixture-build
    time - see tests/fixtures/New-Fixtures.sh).
.NOTES
    PowerShell 5.1+. Dot-sourced by the *.Tests.ps1 files, not part of the PsGit module itself.
#>

function Expand-PsGitTestFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('basic', 'packed', 'refdelta', 'crosscompat')][string]$Name)

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zipPath = Join-Path $PSScriptRoot "fixtures\$Name.zip"
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "Fixture zip not found: $zipPath" }

    $dest = Join-Path ([System.IO.Path]::GetTempPath()) ("psgit-fixture-$Name-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $dest)

    # manifest.json sits BESIDE repo/, not inside it - the extracted repo/ working tree must be
    # exactly what real git checked out, or a status/untracked-file check would see manifest.json
    # itself as a spurious untracked file (it was never part of the real repo's history).
    $manifestPath = Join-Path $dest 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $repoPath = Join-Path $dest 'repo'

    return [pscustomobject]@{ Path = $repoPath; Manifest = $manifest; ExtractRoot = $dest }
}

function Remove-PsGitTestFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $root = Split-Path -Parent $Path
    if ($root -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
