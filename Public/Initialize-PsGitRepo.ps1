function Initialize-PsGitRepo {
    <# .SYNOPSIS Create a minimal .git scaffold (objects, refs, symbolic HEAD, config). Idempotent. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [string]$DefaultBranch = 'main')
    $git = Join-Path $RepoPath '.git'
    if (Test-Path -LiteralPath (Join-Path $git 'HEAD')) { return }
    New-Item -ItemType Directory -Path (Join-Path $git 'objects') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $git 'refs\heads') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $git 'refs\tags') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $git 'HEAD'), "ref: refs/heads/$DefaultBranch`n")
    $config = "[core]`n`trepositoryformatversion = 0`n`tfilemode = false`n`tbare = false`n"
    [System.IO.File]::WriteAllText((Join-Path $git 'config'), $config)
}
