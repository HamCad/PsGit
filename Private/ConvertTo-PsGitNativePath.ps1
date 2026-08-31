function ConvertTo-PsGitNativePath {
    <#
    .SYNOPSIS
        Converts a '/'-separated relative path to the host's native separator.
    .DESCRIPTION
        Model output, git's on-disk formats (index entries, tree entries, ref names) and the /apply
        change contract all use '/'. Converting to the platform separator is a one-liner, and the
        codebase had it written out fourteen times as `-replace '/', '\'` - a LITERAL backslash,
        which is not a separator on Linux or macOS at all.

        That works today only because every one of those sites happens to feed Join-Path, whose
        POSIX implementation normalises the backslash away (verified: `Join-Path /tmp/x
        'Logs\a.jsonl'` yields `/tmp/x/Logs/a.jsonl` and the file lands nested). The correctness is
        therefore accidental, resting on a normalisation none of those call sites mention. The first
        one that concatenates instead - or passes the string to a .NET API rather than a cmdlet -
        gets a file literally named `src\tool.ps1` on Linux, and the bug surfaces far from its cause.

        One helper, one place to test, and the intent is stated instead of implied.

        Uses string .Replace rather than -replace on purpose: on Windows the target separator IS
        '\', and a regex replacement string treats that as an escape character.
    .PARAMETER Path
        A relative path using '/' separators. Empty and $null pass through unchanged.
    .EXAMPLE
        $abs = Join-Path $RepoPath (ConvertTo-PsGitNativePath $entry.Path)
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    return $Path.Replace('/', [string][IO.Path]::DirectorySeparatorChar)
}
