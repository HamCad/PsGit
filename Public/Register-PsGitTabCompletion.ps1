function Register-PsGitTabCompletion {
    <#
    .SYNOPSIS
        Registers tab completion for the `git` wrapper's path-taking subcommands (add, restore,
        unstage, diff), prioritizing staged/unstaged/untracked paths from PsGit's own status
        instead of PowerShell's generic filesystem completion (Gitea #44).
    .DESCRIPTION
        `git` (Public/git.ps1) takes its arguments via $args with no declared parameters, so
        PowerShell has no formal parameter to hang a completer off of - this registers a
        '-Native' argument completer keyed to the command name instead, the same mechanism used
        for completing real native executables. Call once per session (e.g. from a profile,
        alongside the PsGit-aware prompt) to enable it; it does nothing until called.
    .EXAMPLE
        Register-PsGitTabCompletion
        # now `git add <Tab>` cycles pending paths instead of every file under the cwd
    .NOTES
        PowerShell 5.1+. Exported.
    #>
    [CmdletBinding()]
    param()
    Register-ArgumentCompleter -CommandName 'git' -Native -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)

        $tokens = @(($commandAst.ToString()) -split '\s+')
        if ($tokens.Count -lt 2 -or $tokens[1] -notin @('add', 'restore', 'unstage', 'diff')) { return }

        $root = Find-PsGitRepoRoot -StartPath (Get-Location).Path
        if (-not $root) { return }
        $status = Get-PsGitStatus -RepoPath $root

        $candidates = [System.Collections.Generic.List[string]]::new()
        # Order matches what a user is most likely reaching for next: unstaged/untracked first
        # (the usual `git add` target), staged last (mainly useful for `restore --staged`).
        foreach ($e in $status.Unstaged) { $candidates.Add($e.Path) }
        foreach ($p in $status.Untracked) { $candidates.Add($p) }
        foreach ($e in $status.Staged) { $candidates.Add($e.Path) }

        $prefix = $wordToComplete -replace '\\', '/'
        while ($prefix.StartsWith('./')) { $prefix = $prefix.Substring(2) }

        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($c in $candidates) {
            if ($c.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and $seen.Add($c)) {
                [System.Management.Automation.CompletionResult]::new($c, $c, 'ParameterValue', $c)
            }
        }
    }
}
