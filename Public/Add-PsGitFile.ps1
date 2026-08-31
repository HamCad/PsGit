function Add-PsGitFile {
    <# .SYNOPSIS Stage working file(s): write a loose blob and upsert the index entry (mode 100644). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string[]]$Path)
    $byPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($existing in (Read-PsGitIndex -RepoPath $RepoPath)) { $byPath[$existing.Path] = $existing }
    foreach ($rel in $Path) {
        $key = ($rel -replace '\\', '/')
        while ($key.StartsWith('./')) { $key = $key.Substring(2) }
        Assert-PsGitSafeTreePath -Path $key
        $full = Join-Path $RepoPath $rel
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $id = Write-PsGitObject -RepoPath $RepoPath -Type 'blob' -Content $bytes
        $byPath[$key] = [pscustomobject]@{ Path = $key; Mode = '100644'; Id = $id; Size = $bytes.Length }
    }
    Write-PsGitIndex -RepoPath $RepoPath -Entries @($byPath.Values)
}
