function Get-PsGitLog {
    <#
    .SYNOPSIS
        Walk the commit DAG from a ref/HEAD; returns commit records newest-first.
    .DESCRIPTION
        Uses a date-ordered frontier walk (mirrors `git log`'s default traversal): the pending set
        starts with just the start commit, and each step removes and emits whichever pending commit
        has the latest date, THEN adds its not-yet-visited parents to pending. A parent can only
        enter the pending set after its child has already been emitted, so a commit's parents are
        always emitted after it - guaranteed even when two commits share an identical committer
        timestamp (common for scripted/rapid commits, e.g. within the same second), where a flat
        Sort-Object-by-date over the whole visited set does NOT guarantee parent-after-child: the
        DFS visitation order becomes the tiebreaker instead, which can and did put a parent before
        its child in that case.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Ref,
        [int]$Max = 0
    )
    $start = if ($Ref) { Get-PsGitRef -RepoPath $RepoPath -Name $Ref } else { (Get-PsGitHead -RepoPath $RepoPath).Id }
    if (-not $start) { return @() }

    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $records = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[object]]::new()   # @{ Id; Tree; Parents; Author; Committer; Message; Date }

    $obj = Get-PsGitObject -RepoPath $RepoPath -Id $start
    if ($obj.Type -ne 'commit') { return @() }
    $c = ConvertFrom-PsGitCommit -Content $obj.Content
    $pending.Add([pscustomobject]@{
        Id = $start; Tree = $c.Tree; Parents = $c.Parents
        Author = $c.Author; Committer = $c.Committer; Message = $c.Message
        Date = (ConvertFrom-PsGitIdentity -Line $c.Committer).Date
    })
    [void]$visited.Add($start)

    while ($pending.Count -gt 0) {
        $bestIdx = 0
        for ($i = 1; $i -lt $pending.Count; $i++) { if ($pending[$i].Date -gt $pending[$bestIdx].Date) { $bestIdx = $i } }
        $current = $pending[$bestIdx]
        $pending.RemoveAt($bestIdx)
        $records.Add($current)

        foreach ($p in $current.Parents) {
            if ($visited.Add($p)) {
                $pobj = Get-PsGitObject -RepoPath $RepoPath -Id $p
                $pc = ConvertFrom-PsGitCommit -Content $pobj.Content
                $pending.Add([pscustomobject]@{
                    Id = $p; Tree = $pc.Tree; Parents = $pc.Parents
                    Author = $pc.Author; Committer = $pc.Committer; Message = $pc.Message
                    Date = (ConvertFrom-PsGitIdentity -Line $pc.Committer).Date
                })
            }
        }
    }
    if ($Max -gt 0 -and $records.Count -gt $Max) { return @($records.GetRange(0, $Max)) }
    return @($records)
}
