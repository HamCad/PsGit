function git {
    <#
    .SYNOPSIS
        Native-syntax entry point: `git status`, `git add .`, `git commit -m "msg"`, `git log 5`,
        `git help`/`git -h`/`git --help`, exactly as you'd type them against real git - not
        Invoke-PsGitCommand's single quoted CommandInput string.
    .DESCRIPTION
        A thin wrapper, deliberately taking its input via the automatic $args variable instead of
        a declared param block. A declared `[Parameter(Position = 0)]$Subcommand` makes
        PowerShell's own parameter binder try to match any dash-prefixed token (e.g. `-h`,
        `--help`) against a parameter name before this function's body ever runs - it doesn't
        match anything here and throws, so `git -h`/`git --help` never reached the dispatcher at
        all (see #31/#33). Reading $args instead skips that binder entirely: every token, dashes
        included, arrives untouched. Re-quotes any element containing whitespace (e.g. a commit
        message) and hands the reassembled subcommand line to Invoke-PsGitCommand.

        Safe to define under this name here: PsGit only targets machines with no git.exe on PATH
        (this module has no push/fetch/clone and never checks for or shells out to real git), so
        there is nothing named `git` to shadow.
    .EXAMPLE
        git status
    .EXAMPLE
        git add .
    .EXAMPLE
        git commit -m "initial commit"
    .EXAMPLE
        git help
    .NOTES
        PowerShell 5.1+. Exported.
    #>
    $subcommand = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
    $quoted = @($rest | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
    $tail = $quoted -join ' '
    $cmdInput = if ($subcommand -and $tail) { "$subcommand $tail" } else { $subcommand }
    Invoke-PsGitCommand -CommandInput $cmdInput
}
