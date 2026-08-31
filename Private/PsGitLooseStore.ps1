function Write-PsGitObject {
    <# .SYNOPSIS Write a loose, zlib-compressed git object; returns its id (idempotent). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Type,
        [byte[]]$Content = @()
    )
    $framed = Format-PsGitFramedObject -Type $Type -Content $Content
    $id = Get-PsGitObjectId -Type $Type -Content $Content
    $dir = Join-Path $RepoPath ".git\objects\$($id.Substring(0,2))"
    $file = Join-Path $dir $id.Substring(2)
    if (Test-Path -LiteralPath $file) { return $id }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bytes = ConvertTo-PsGitZlibBytes -Content $framed
    [System.IO.File]::WriteAllBytes($file, $bytes)
    return $id
}

function Read-PsGitLooseObject {
    <# .SYNOPSIS Read a loose git object by id; returns @{ Type; Content } or $null if absent. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Id)
    $file = Join-Path $RepoPath ".git\objects\$($Id.Substring(0,2))\$($Id.Substring(2))"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $decompressed = Expand-PsGitZlibBytes -Buffer $bytes -Offset 0
    $parsed = ConvertFrom-PsGitFramed -Raw $decompressed
    return [pscustomobject]@{ Type = $parsed.Type; Content = $parsed.Content }
}
