function git {
    <#
    .SYNOPSIS
        Native-syntax entry point: `git status`, `git add .`, `git commit -m "msg"`, `git log 5`,
        exactly as you'd type them against real git - not Invoke-PsGitCommand's single quoted
        CommandInput string.
    .DESCRIPTION
        A thin wrapper: PowerShell's own command-mode parser already splits the space-separated
        arguments into $Rest, so this just re-quotes any element containing whitespace (e.g. a
        commit message) and hands the reassembled subcommand line to Invoke-PsGitCommand.

        Safe to define under this name here: PsGit only targets machines with no git.exe on PATH
        (this module has no push/fetch/clone and never checks for or shells out to real git), so
        there is nothing named `git` to shadow.
    .PARAMETER Subcommand
        The git subcommand, e.g. 'status', 'add', 'commit', 'log', 'diff', 'branch', 'checkout'.
    .PARAMETER Rest
        Everything after the subcommand, taken verbatim from the command line.
    .EXAMPLE
        git status
    .EXAMPLE
        git add .
    .EXAMPLE
        git commit -m "initial commit"
    .NOTES
        PowerShell 5.1+. Exported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Subcommand,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
    )
    $quoted = @($Rest | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
    $tail = $quoted -join ' '
    $cmdInput = if ($Subcommand -and $tail) { "$Subcommand $tail" } else { $Subcommand }
    Invoke-PsGitCommand -CommandInput $cmdInput
}
