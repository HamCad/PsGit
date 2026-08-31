$script:PsGitReservedDeviceNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

function Test-PsGitSafeRefName {
    <#
    .SYNOPSIS
        Checks whether a branch/ref short name (e.g. 'main', 'feature/x') is safe to turn into a
        loose ref file path.
    .DESCRIPTION
        Two independent hazards, both from Gitea issue #14:

          1. A path component matching a Windows reserved device name (CON, PRN, AUX, NUL,
             COM1-9, LPT1-9 - checked case-insensitively, and before any extension, since
             Windows reserves 'con.txt' just as much as 'con') silently redirects a file write to
             the device instead of creating a file. `New-PsGitBranch 'con'` would otherwise report
             success while no ref file is ever created on disk.
          2. The character/shape rules real git's own `check-ref-format` enforces, so PsGit
             doesn't accept ref names that would corrupt its own loose-ref layout or confuse a
             real git reading the same repo: no empty name or path component, no leading '.' on a
             component, no '..' anywhere, no trailing '.lock', no trailing '.', no '@{', not
             exactly '@', and none of the characters git forbids in a ref
             (space, '~', '^', ':', '?', '*', '[', '\', or an ASCII control character).
    .PARAMETER Name
        A ref short name (branch name) or full ref path (e.g. 'refs/heads/main').
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure - no filesystem access.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.StartsWith('/') -or $Name.EndsWith('/')) { return $false }
    if ($Name.Contains('//')) { return $false }
    if ($Name.Contains('..')) { return $false }
    if ($Name.Contains('@{')) { return $false }
    if ($Name -eq '@') { return $false }

    foreach ($ch in $Name.ToCharArray()) {
        if ([int]$ch -lt 32) { return $false }
        if ('~^:?*[\ '.IndexOf($ch) -ge 0) { return $false }
    }

    foreach ($segment in $Name.Split('/')) {
        if ([string]::IsNullOrEmpty($segment)) { return $false }
        if ($segment.StartsWith('.')) { return $false }
        if ($segment.EndsWith('.') -or $segment.EndsWith('.lock')) { return $false }
        $bare = $segment.Split('.')[0]
        if ($script:PsGitReservedDeviceNames -icontains $bare) { return $false }
    }
    return $true
}

function Assert-PsGitSafeRefName {
    <# .SYNOPSIS Throws if $Name fails Test-PsGitSafeRefName. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Name)

    if (-not (Test-PsGitSafeRefName -Name $Name)) {
        throw "Invalid ref name '$Name': must not collide with a Windows reserved device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9) and must follow git's own ref-name rules (no empty/leading-dot component, no '..', no trailing '.'/'.lock', no '@{', and none of space ~^:?*[\\ or a control character)."
    }
}
