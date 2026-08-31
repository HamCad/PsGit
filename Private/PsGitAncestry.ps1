function Test-PsGitIsAncestor {
    <#
    .SYNOPSIS
        True if $AncestorId is $DescendantId itself, or reachable by walking parent links from it
        (i.e. $AncestorId's commit is merged into $DescendantId's history).
    .NOTES
        PowerShell 5.1+. Private (not exported). Plain DFS over commit parents - same object
        access Get-PsGitLog already uses, just without the date-ordering that command needs for
        display and this one doesn't.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$AncestorId, [Parameter(Mandatory)][string]$DescendantId)
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($DescendantId)
    while ($stack.Count -gt 0) {
        $id = $stack.Pop()
        if (-not $visited.Add($id)) { continue }
        if ($id -eq $AncestorId) { return $true }
        $obj = Get-PsGitObject -RepoPath $RepoPath -Id $id
        if ($obj.Type -ne 'commit') { continue }
        $c = ConvertFrom-PsGitCommit -Content $obj.Content
        foreach ($p in $c.Parents) { $stack.Push($p) }
    }
    return $false
}
