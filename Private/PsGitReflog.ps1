function Format-PsGitIdentityTimestamp {
    <# .SYNOPSIS "<epoch> <tz>" for a DateTimeOffset, in the form git uses in commit/reflog identity lines. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.DateTimeOffset]$Date)
    $epoch = $Date.ToUnixTimeSeconds()
    $off = $Date.Offset
    $sign = if ($off.Ticks -lt 0) { '-' } else { '+' }
    $tz = '{0}{1:00}{2:00}' -f $sign, [Math]::Abs($off.Hours), [Math]::Abs($off.Minutes)
    return "$epoch $tz"
}

function Add-PsGitReflogEntry {
    <#
    .SYNOPSIS
        Append one line to a ref's reflog (.git/logs/HEAD or .git/logs/refs/heads/<name>), in
        git's plain-text format: "<old-sha> <new-sha> <name> <email> <epoch> <tz>\t<message>".
    .DESCRIPTION
        Creates the reflog file (and its parent directory) on first write - real git does the
        same the first time a ref moves. $OldId may be $null/empty for a ref that didn't exist
        before (a new branch, the first commit on an unborn HEAD): git records that as the all-
        zero id.
    .PARAMETER RefName
        'HEAD', or a full ref like 'refs/heads/main'. Mirrors the on-disk layout under .git/logs/.
    .NOTES
        PowerShell 5.1+. Private (not exported).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RefName,
        [AllowEmptyString()][AllowNull()][string]$OldId,
        [Parameter(Mandatory)][string]$NewId,
        [Parameter(Mandatory)][string]$Message,
        [string]$Name = 'PsGit',
        [string]$Email = 'psgit@localhost',
        [System.DateTimeOffset]$Date = [System.DateTimeOffset]::Now
    )
    $old = if ([string]::IsNullOrEmpty($OldId)) { '0' * 40 } else { $OldId }
    $stamp = Format-PsGitIdentityTimestamp -Date $Date
    $line = "$old $NewId $Name <$Email> $stamp`t$Message`n"
    $file = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'logs' (ConvertTo-PsGitNativePath $RefName)))
    $dir = Split-Path -Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::AppendAllText($file, $line)
}

function Remove-PsGitReflog {
    <# .SYNOPSIS Delete a ref's reflog file, mirroring real git dropping logs/refs/heads/<name> when the ref itself is deleted. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$RefName)
    $file = Join-Path $RepoPath (Join-Path '.git' (Join-Path 'logs' (ConvertTo-PsGitNativePath $RefName)))
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
