function Get-PsGitRef {
    <# .SYNOPSIS Resolve a full ref name (e.g. refs/heads/main) to an id via loose then packed-refs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name)
    $loose = Join-Path $RepoPath (Join-Path '.git' (ConvertTo-PsGitNativePath $Name))
    if (Test-Path -LiteralPath $loose) {
        return (Get-Content -LiteralPath $loose -Raw).Trim()
    }
    $packed = Join-Path $RepoPath '.git\packed-refs'
    if (Test-Path -LiteralPath $packed) {
        foreach ($line in (Get-Content -LiteralPath $packed)) {
            if ($line.StartsWith('#') -or $line.StartsWith('^') -or -not $line.Trim()) { continue }
            $sp = $line.IndexOf(' ')
            if ($sp -lt 0) { continue }
            if ($line.Substring($sp + 1).Trim() -eq $Name) { return $line.Substring(0, $sp) }
        }
    }
    return $null
}

function Get-PsGitHead {
    <# .SYNOPSIS Read HEAD; returns @{ Symbolic; Ref; Id } (Id null for an unborn branch). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $headFile = Join-Path $RepoPath '.git\HEAD'
    if (-not (Test-Path -LiteralPath $headFile)) {
        return [pscustomobject]@{ Symbolic = $false; Ref = $null; Id = $null }
    }
    $head = (Get-Content -LiteralPath $headFile -Raw).Trim()
    if ($head.StartsWith('ref: ')) {
        $ref = $head.Substring(5).Trim()
        return [pscustomobject]@{ Symbolic = $true; Ref = $ref; Id = (Get-PsGitRef -RepoPath $RepoPath -Name $ref) }
    }
    return [pscustomobject]@{ Symbolic = $false; Ref = $null; Id = $head }
}

function Set-PsGitRef {
    <# .SYNOPSIS Write a loose ref file (e.g. refs/heads/main) with an id. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Id)
    $file = Join-Path $RepoPath (Join-Path '.git' (ConvertTo-PsGitNativePath $Name))
    $dir = Split-Path -Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($file, "$Id`n")
    # Belt-and-suspenders backstop for #14: a ref name that reaches here without going through
    # Assert-PsGitSafeRefName (e.g. a reserved Windows device name like 'con') can make
    # WriteAllText silently redirect to the device instead of creating a file - re-verify the
    # write actually landed rather than trusting WriteAllText's silent success.
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Failed to write ref '$Name': no file exists at '$file' after writing (possible reserved device name or invalid path)."
    }
}
