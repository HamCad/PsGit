function Find-PsGitRepoRoot {
    <#
    .SYNOPSIS
        Walks upward from StartPath looking for a directory containing a recognizable .git
        (Gitea #46: real git works from any subdirectory of a project, not just the root).
    .DESCRIPTION
        Mirrors real git's own repo-discovery: start at the given directory and check each
        ancestor (including itself) for '.git\HEAD' until the filesystem root is reached.
        Returns $null - never throws - when no ancestor qualifies, leaving the "not a git
        repository" decision to the caller.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StartPath)

    $dir = [System.IO.Path]::GetFullPath($StartPath)
    while ($true) {
        $headFile = Join-Path (Join-Path $dir '.git') 'HEAD'
        if (Test-Path -LiteralPath $headFile) { return $dir }
        $parent = Split-Path -Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
}
