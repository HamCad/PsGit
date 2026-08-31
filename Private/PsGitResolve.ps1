function Resolve-PsGitId {
    <# .SYNOPSIS Resolve a full or abbreviated id to a full id, searching loose objects and packs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Id)
    $id = $Id.ToLowerInvariant()
    if ($id -notmatch '^[0-9a-f]{4,40}$') { throw "Invalid object id '$Id'." }
    if ($id.Length -eq 40) { return $id }
    $found = [System.Collections.Generic.HashSet[string]]::new()
    $dir = Join-Path $RepoPath ".git\objects\$($id.Substring(0,2))"
    if (Test-Path -LiteralPath $dir) {
        $rest = $id.Substring(2)
        foreach ($f in (Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name.StartsWith($rest) })) {
            [void]$found.Add($id.Substring(0, 2) + $f.Name)
        }
    }
    foreach ($packId in (Resolve-PsGitPackId -RepoPath $RepoPath -Prefix $id)) { [void]$found.Add($packId) }
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw "Ambiguous object id '$Id' ($($found.Count) matches)." }
    return @($found)[0]
}

function Get-PsGitObject {
    <# .SYNOPSIS Fetch a git object (@{Type;Content}) by full/abbreviated id from loose objects or packs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Id)
    $full = Resolve-PsGitId -RepoPath $RepoPath -Id $Id
    if ($full) {
        $loose = Read-PsGitLooseObject -RepoPath $RepoPath -Id $full
        if ($loose) { return $loose }
        $packed = Get-PsGitPackObject -RepoPath $RepoPath -Id $full
        if ($packed) { return $packed }
    }
    throw "Git object not found: '$Id'."
}
