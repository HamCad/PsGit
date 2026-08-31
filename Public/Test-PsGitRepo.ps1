function Test-PsGitRepo {
    <# .SYNOPSIS Detect a git repo at RepoPath and report whether the engine supports it. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $gitDir = Join-Path $RepoPath '.git'
    $headFile = Join-Path $gitDir 'HEAD'
    if (-not (Test-Path -LiteralPath $headFile)) {
        return [pscustomobject]@{
            IsRepo = $false; GitDir = $null; ObjectFormat = 'sha1'
            Supported = $false; Reason = 'not a git repository'
        }
    }
    $format = 'sha1'
    $configFile = Join-Path $gitDir 'config'
    if (Test-Path -LiteralPath $configFile) {
        foreach ($line in (Get-Content -LiteralPath $configFile)) {
            if ($line -match '^\s*objectformat\s*=\s*(\S+)') { $format = $Matches[1].ToLowerInvariant() }
        }
    }
    if ($format -ne 'sha1') {
        return [pscustomobject]@{
            IsRepo = $true; GitDir = $gitDir; ObjectFormat = $format
            Supported = $false; Reason = "unsupported object format '$format' (only sha1)"
        }
    }
    return [pscustomobject]@{
        IsRepo = $true; GitDir = $gitDir; ObjectFormat = 'sha1'; Supported = $true; Reason = 'ok'
    }
}
