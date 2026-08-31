function Format-PsGitHeaderSpan {
    <# .SYNOPSIS Format a header git span (branch + dirty count) into @{ Text; Role }. Pure. #>
    [CmdletBinding()]
    param([string]$Branch = '', [int]$DirtyCount = 0, [bool]$IsRepo = $true)
    if (-not $IsRepo -or [string]::IsNullOrWhiteSpace($Branch)) {
        return @{ Text = ''; Role = 'header-meta' }
    }
    if ($DirtyCount -gt 0) {
        return @{ Text = ('git ' + $Branch + ' ' + [char]0x25CF + $DirtyCount); Role = 'notice-warn' }
    }
    return @{ Text = ('git ' + $Branch + ' ' + [char]0x2713); Role = 'glyph-ok' }
}
