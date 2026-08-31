function Get-PsGitBranch {
    <# .SYNOPSIS List local branches (@{ Name; Id; IsCurrent }) from refs/heads + packed-refs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $head = Get-PsGitHead -RepoPath $RepoPath
    $current = if ($head.Symbolic) { $head.Ref -replace '^refs/heads/', '' } else { $null }
    $result = [System.Collections.Generic.List[object]]::new()
    $headsDir = Join-Path $RepoPath '.git\refs\heads'
    if (Test-Path -LiteralPath $headsDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $headsDir -File -Recurse)) {
            $name = ($f.FullName.Substring($headsDir.Length + 1) -replace '\\', '/')
            $result.Add([pscustomobject]@{ Name = $name; Id = (Get-Content -LiteralPath $f.FullName -Raw).Trim(); IsCurrent = ($name -eq $current) })
        }
    }
    $packed = Join-Path $RepoPath '.git\packed-refs'
    if (Test-Path -LiteralPath $packed) {
        foreach ($line in (Get-Content -LiteralPath $packed)) {
            if ($line.StartsWith('#') -or $line.StartsWith('^') -or -not $line.Trim()) { continue }
            $sp = $line.IndexOf(' ')
            if ($sp -lt 0) { continue }
            $ref = $line.Substring($sp + 1).Trim()
            if ($ref.StartsWith('refs/heads/')) {
                $name = $ref.Substring(11)
                if (-not ($result | Where-Object { $_.Name -eq $name })) {
                    $result.Add([pscustomobject]@{ Name = $name; Id = $line.Substring(0, $sp); IsCurrent = ($name -eq $current) })
                }
            }
        }
    }
    return @($result | Sort-Object Name)
}
