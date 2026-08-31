function Get-PsGitDiff {
    <# .SYNOPSIS Unified diff of the staged/HEAD blob vs the working file for a path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Path)
    $rel = $Path -replace '\\', '/'
    $oldBytes = $null
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) {
        if ($e.Path -eq $rel) { $oldBytes = (Get-PsGitObject -RepoPath $RepoPath -Id $e.Id).Content; break }
    }
    $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $rel)
    $newBytes = if (Test-Path -LiteralPath $abs) { [System.IO.File]::ReadAllBytes($abs) } else { [byte[]]@() }
    if (($oldBytes -and ([Array]::IndexOf($oldBytes, [byte]0) -ge 0)) -or `
        ($newBytes -and ([Array]::IndexOf($newBytes, [byte]0) -ge 0))) {
        return 'Binary files differ'
    }
    $oldText = if ($oldBytes) { [System.Text.Encoding]::UTF8.GetString($oldBytes) } else { '' }
    $newText = if ($newBytes) { [System.Text.Encoding]::UTF8.GetString($newBytes) } else { '' }
    $oldLines = if ($oldText -eq '') { @() } else { $oldText -split "`n" }
    $newLines = if ($newText -eq '') { @() } else { $newText -split "`n" }
    return (Get-PsGitDiffLine -OldLines $oldLines -NewLines $newLines) -join "`n"
}
