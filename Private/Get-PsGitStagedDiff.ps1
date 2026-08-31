function Get-PsGitStagedDiff {
    <# .SYNOPSIS Build the staged (index-vs-HEAD) diff as text for the AI commit-message draft. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)
    $st = Get-PsGitStatus -RepoPath $RepoPath
    $staged = @($st.Staged)
    if ($staged.Count -eq 0) { return '' }

    $headMap = @{}
    $head = Get-PsGitHead -RepoPath $RepoPath
    if ($head.Id) {
        $tree = (ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $RepoPath -Id $head.Id).Content).Tree
        foreach ($e in (Expand-PsGitTree -RepoPath $RepoPath -TreeId $tree)) { $headMap[$e.Path] = $e.Id }
    }
    $idxMap = @{}
    foreach ($e in (Read-PsGitIndex -RepoPath $RepoPath)) { $idxMap[$e.Path] = $e.Id }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($s in $staged) {
        $old = @()
        if ($headMap.ContainsKey($s.Path)) {
            $t = [System.Text.Encoding]::UTF8.GetString((Get-PsGitObject -RepoPath $RepoPath -Id $headMap[$s.Path]).Content)
            $old = if ($t -eq '') { @() } else { $t -split "`n" }
        }
        $new = @()
        if ($idxMap.ContainsKey($s.Path)) {
            $t = [System.Text.Encoding]::UTF8.GetString((Get-PsGitObject -RepoPath $RepoPath -Id $idxMap[$s.Path]).Content)
            $new = if ($t -eq '') { @() } else { $t -split "`n" }
        }
        [void]$sb.AppendLine("--- $($s.Path) ($($s.State))")
        $hunks = Get-PsGitDiffLine -OldLines $old -NewLines $new
        if ($hunks) { [void]$sb.AppendLine(($hunks -join "`n")) }
    }
    return $sb.ToString()
}
