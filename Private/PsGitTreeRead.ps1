function Expand-PsGitTree {
    <# .SYNOPSIS Recursively flatten a tree object to @{ Path; Mode; Id } blob entries. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$TreeId, [string]$Prefix = '')
    $obj = Get-PsGitObject -RepoPath $RepoPath -Id $TreeId
    if ($obj.Type -ne 'tree') { throw "Object $TreeId is a '$($obj.Type)', not a tree." }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($e in (ConvertFrom-PsGitTree -Content $obj.Content)) {
        $path = if ($Prefix) { "$Prefix/$($e.Name)" } else { $e.Name }
        Assert-PsGitSafeTreePath -Path $path
        if ($e.Mode -eq '40000') {
            foreach ($child in (Expand-PsGitTree -RepoPath $RepoPath -TreeId $e.Id -Prefix $path)) { $result.Add($child) }
        } else {
            $result.Add([pscustomobject]@{ Path = $path; Mode = $e.Mode; Id = $e.Id })
        }
    }
    return $result.ToArray()
}
