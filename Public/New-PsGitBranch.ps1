function New-PsGitBranch {
    <# .SYNOPSIS Create a branch ref pointing at StartId (defaults to HEAD). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Name, [string]$StartId)
    Assert-PsGitSafeRefName -Name $Name
    if (-not $StartId) { $StartId = (Get-PsGitHead -RepoPath $RepoPath).Id }
    if (-not $StartId) { throw "Cannot create branch '$Name': no commit to point at." }
    $file = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'refs' (Join-Path 'heads' (ConvertTo-PsGitNativePath $Name))))
    if (Test-Path -LiteralPath $file) { throw "Branch '$Name' already exists." }
    Set-PsGitRef -RepoPath $RepoPath -Name "refs/heads/$Name" -Id $StartId
    Add-PsGitReflogEntry -RepoPath $RepoPath -RefName "refs/heads/$Name" -OldId $null -NewId $StartId -Message "branch: Created from $StartId"
}
