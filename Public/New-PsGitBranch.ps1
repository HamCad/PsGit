function New-PsGitBranch {
    <# .SYNOPSIS Create a branch ref pointing at StartId (defaults to HEAD). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [string]$StartId)
    Assert-PsGitSafeRefName -Name $Name
    if (-not $StartId) { $StartId = (Get-PsGitHead -RepoPath $RepoPath).Id }
    if (-not $StartId) { throw "Cannot create branch '$Name': no commit to point at." }
    $file = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'refs' (Join-Path 'heads' (ConvertTo-PsGitNativePath $Name))))
    if (Test-Path -LiteralPath $file -PathType Leaf) { throw "Branch '$Name' already exists." }
    # A directory at this path (rather than a leaf ref file) means nested branches already exist
    # under this name (e.g. 'baz/qux') - same D/F-conflict class Assert-PsGitNoRefPathConflict
    # catches in the other direction, just caught earlier here since no branch named exactly
    # $Name can exist yet. Give the accurate reason instead of "already exists".
    if (Test-Path -LiteralPath $file -PathType Container) { throw "Cannot create branch '$Name': nested branch(es) already exist under 'refs/heads/$Name/'." }
    Set-PsGitRef -RepoPath $RepoPath -Name "refs/heads/$Name" -Id $StartId
    Add-PsGitReflogEntry -RepoPath $RepoPath -RefName "refs/heads/$Name" -OldId $null -NewId $StartId -Message "branch: Created from $StartId"
}
