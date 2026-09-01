function Add-PsGitFile {
    <#
    .SYNOPSIS
        Stage working file(s): write a loose blob and upsert the index entry (mode 100644), or -
        for a tracked path that no longer exists on disk - remove it from the index, matching
        real git's "git add" staging a working-tree delete (Gitea #43).
    .PARAMETER ContinueOnError
        Skip a path that exists but can't be read right now (locked by another process,
        permission denied, etc.) instead of throwing and abandoning the whole call - one
        CAD-locked file out of hundreds otherwise threw away every other file's staging along
        with it (Gitea #45). Off by default so direct/programmatic callers keep the original
        fail-fast contract; the interactive `git add` CLI path opts in.
    .OUTPUTS
        With -ContinueOnError: pscustomobject[] with Path/Error for each requested path that
        could not be staged (empty if everything succeeded). Without it: nothing - a failure
        throws instead, as before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$ContinueOnError
    )
    $byPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($existing in (Read-PsGitIndex -RepoPath $RepoPath)) { $byPath[$existing.Path] = $existing }
    $failures = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in $Path) {
        $key = ($rel -replace '\\', '/')
        while ($key.StartsWith('./')) { $key = $key.Substring(2) }
        Assert-PsGitSafeTreePath -Path $key
        $full = Join-Path $RepoPath (ConvertTo-PsGitNativePath $key)
        if (-not (Test-Path -LiteralPath $full)) {
            if (-not $byPath.Remove($key)) {
                $msg = "pathspec '$rel' did not match any tracked or working files"
                if ($ContinueOnError) { $failures.Add([pscustomobject]@{ Path = $rel; Error = $msg }); continue }
                throw $msg
            }
            continue
        }
        if ($ContinueOnError) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($full)
                $id = Write-PsGitObject -RepoPath $RepoPath -Type 'blob' -Content $bytes
                $byPath[$key] = [pscustomobject]@{ Path = $key; Mode = '100644'; Id = $id; Size = $bytes.Length }
            } catch {
                $failures.Add([pscustomobject]@{ Path = $rel; Error = $_.Exception.Message })
            }
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $id = Write-PsGitObject -RepoPath $RepoPath -Type 'blob' -Content $bytes
            $byPath[$key] = [pscustomobject]@{ Path = $key; Mode = '100644'; Id = $id; Size = $bytes.Length }
        }
    }
    Write-PsGitIndex -RepoPath $RepoPath -Entries @($byPath.Values)
    if ($ContinueOnError) { return $failures.ToArray() }
}
