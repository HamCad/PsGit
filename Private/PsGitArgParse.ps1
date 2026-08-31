function ConvertTo-PsGitArgTokens {
    <#
    .SYNOPSIS
        Quote-aware whitespace tokenizer for a CLI argument string.
    .DESCRIPTION
        Like `-split '\s+'`, but a double-quoted span (e.g. "Meeting Notes.docx") is kept as one
        token with its surrounding quotes stripped, instead of being split apart on the space
        inside it. Used by Invoke-PsGitCommand so re-quoted arguments from `git.ps1` (or a caller
        building the CommandInput string directly) survive intact.
    .PARAMETER Text
        The raw argument string, e.g. '"Meeting Notes.docx" other.txt'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Text, '"([^"]*)"|(\S+)')) {
        $tokens.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }))
    }
    return @($tokens)
}
