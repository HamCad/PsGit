function New-PsGitCommit {
    <# .SYNOPSIS Build a tree from the index, write a commit object, and advance the current branch. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string]$Name = 'PsGit',
        [string]$Email = 'psgit@localhost',
        [System.DateTimeOffset]$Date = [System.DateTimeOffset]::Now
    )
    $entries = Read-PsGitIndex -RepoPath $RepoPath
    $tree = ConvertTo-PsGitTree -RepoPath $RepoPath -Entries $entries
    $head = Get-PsGitHead -RepoPath $RepoPath
    if ($head.Id) {
        $parentTree = (ConvertFrom-PsGitCommit -Content (Get-PsGitObject -RepoPath $RepoPath -Id $head.Id).Content).Tree
        if ($tree -eq $parentTree) {
            throw 'nothing to commit, working tree clean'
        }
    }
    $stamp = Format-PsGitIdentityTimestamp -Date $Date
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("tree $tree`n")
    if ($head.Id) { [void]$sb.Append("parent $($head.Id)`n") }
    [void]$sb.Append("author $Name <$Email> $stamp`n")
    [void]$sb.Append("committer $Name <$Email> $stamp`n")
    [void]$sb.Append("`n")
    $msg = if ($Message.EndsWith("`n")) { $Message } else { "$Message`n" }
    [void]$sb.Append($msg)
    $content = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $commitId = Write-PsGitObject -RepoPath $RepoPath -Type 'commit' -Content $content
    $reflogMsg = if ($head.Id) { "commit: $Message" } else { "commit (initial): $Message" }
    if ($head.Symbolic) {
        Set-PsGitRef -RepoPath $RepoPath -Name $head.Ref -Id $commitId
        Add-PsGitReflogEntry -RepoPath $RepoPath -RefName $head.Ref -OldId $head.Id -NewId $commitId -Message $reflogMsg -Name $Name -Email $Email -Date $Date
    } else {
        [System.IO.File]::WriteAllText((Join-Path $RepoPath '.git\HEAD'), "$commitId`n")
    }
    Add-PsGitReflogEntry -RepoPath $RepoPath -RefName 'HEAD' -OldId $head.Id -NewId $commitId -Message $reflogMsg -Name $Name -Email $Email -Date $Date
    return $commitId
}
