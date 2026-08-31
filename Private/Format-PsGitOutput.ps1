function Format-PsGitStatusLine {
    <# .SYNOPSIS Format a Get-PsGitStatus record into colored @{ Text; Color } lines. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Status)
    $lines = [System.Collections.Generic.List[object]]::new()
    $lines.Add(@{ Text = "On branch $($Status.Branch)"; Color = 'Cyan' })
    $staged = @($Status.Staged); $unstaged = @($Status.Unstaged); $untracked = @($Status.Untracked)
    if ($staged.Count -eq 0 -and $unstaged.Count -eq 0 -and $untracked.Count -eq 0) {
        $lines.Add(@{ Text = 'nothing to commit, working tree clean'; Color = 'Green' })
        return $lines.ToArray()
    }
    if ($staged.Count) {
        $lines.Add(@{ Text = 'Staged:'; Color = 'Gray' })
        foreach ($e in $staged) { $lines.Add(@{ Text = "  $($e.State.PadRight(9)) $($e.Path)"; Color = 'Green' }) }
    }
    if ($unstaged.Count) {
        $lines.Add(@{ Text = 'Changed (unstaged):'; Color = 'Gray' })
        foreach ($e in $unstaged) { $lines.Add(@{ Text = "  $($e.State.PadRight(9)) $($e.Path)"; Color = 'Red' }) }
    }
    if ($untracked.Count) {
        $lines.Add(@{ Text = 'Untracked:'; Color = 'Gray' })
        foreach ($p in $untracked) { $lines.Add(@{ Text = "  $p"; Color = 'DarkYellow' }) }
    }
    return $lines.ToArray()
}

function Format-PsGitStatusPorcelain {
    <# .SYNOPSIS Format a Get-PsGitStatus record as `git status --porcelain` XY-code lines, e.g. 'M  path', ' M path', '?? path'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Status)
    $codeFor = @{ added = 'A'; modified = 'M'; deleted = 'D' }
    $map = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($e in @($Status.Staged)) {
        if (-not $map.ContainsKey($e.Path)) { $map[$e.Path] = [char[]](' ', ' ') }
        $map[$e.Path][0] = $codeFor[$e.State]
    }
    foreach ($e in @($Status.Unstaged)) {
        if (-not $map.ContainsKey($e.Path)) { $map[$e.Path] = [char[]](' ', ' ') }
        $map[$e.Path][1] = $codeFor[$e.State]
    }
    foreach ($p in @($Status.Untracked)) { $map[$p] = [char[]]('?', '?') }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($p in ($map.Keys | Sort-Object)) {
        $xy = $map[$p]
        $lines.Add("$($xy[0])$($xy[1]) $p")
    }
    return $lines.ToArray()
}

function Format-PsGitLogLine {
    <# .SYNOPSIS Format commit records into 'shortid  yyyy-MM-dd  subject' colored lines. #>
    [CmdletBinding()]
    param([object[]]$Commits = @())
    $lines = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Commits) {
        $short = $c.Id.Substring(0, 7)
        $date = $c.Date.ToString('yyyy-MM-dd')
        $subject = (($c.Message -split "`n", 2)[0]).Trim()
        $lines.Add(@{ Text = "$short  $date  $subject"; Color = 'Gray' })
    }
    if ($lines.Count -eq 0) { $lines.Add(@{ Text = 'no commits yet'; Color = 'DarkGray' }) }
    return $lines.ToArray()
}

function Format-PsGitHelpLine {
    <# .SYNOPSIS Build 'git help' output - command list, examples, general usage - as colored @{ Text; Color } lines. #>
    [CmdletBinding()]
    param()
    $lines = [System.Collections.Generic.List[object]]::new()
    $add = { param($Text, $Color = 'Gray') $lines.Add(@{ Text = $Text; Color = $Color }) }

    & $add 'PsGit - a pure-PowerShell reimplementation of local git' 'Cyan'
    & $add '(no remotes: no clone/push/pull/fetch)' 'DarkGray'
    & $add ''
    & $add 'Commands:' 'Cyan'
    $cmds = @(
        , @('git init', 'Initialize a new repository')
        , @('git status [--porcelain]', 'Show working tree status')
        , @('git add <path...> | .', 'Stage files (. stages every changed file)')
        , @('git commit -m "<message>"', 'Commit staged changes')
        , @('git log [N]', 'Show commit history (default 15)')
        , @('git diff [<path>]', 'Show unstaged changes')
        , @('git branch', 'List branches')
        , @('git branch new <name>', 'Create a branch')
        , @('git branch rm <name> [-f|--force|-D]', 'Delete a branch (-f/--force/-D forces an unmerged one)')
        , @('git checkout <branch|commit>', 'Switch branches (working tree must be clean or confirmed)')
        , @('git checkout -b <new-branch> [<start-point>]', 'Create a branch (from HEAD, or <start-point>) and switch to it')
        , @('git restore <path...> | .', 'Discard unstaged edits in path(s), from the index')
        , @('git restore --staged <path...> | .', 'Unstage path(s) (alias: git unstage <path...>)')
        , @('git reset [<path...>]', 'Unstage path(s), or everything with no path')
        , @('git reset --hard', 'Reset index and working tree to HEAD (discards everything)')
        , @('git help | -h | --help', 'Show this help')
    )
    $width = ($cmds | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum
    foreach ($c in $cmds) { & $add ('  {0}  {1}' -f $c[0].PadRight($width), $c[1]) }
    & $add ''
    & $add 'Examples:' 'Cyan'
    foreach ($ex in @(
        'git init'
        'git add .'
        'git commit -m "initial commit"'
        'git status --porcelain'
        'git log 5'
        'git branch new feature-x'
        'git checkout feature-x'
        'git checkout -b feature-y'
        'git branch rm feature-x -f'
        'git restore firstfile.txt'
        'git restore --staged firstfile.txt'
        'git reset'
        'git reset --hard'
    )) { & $add "  $ex" }
    & $add ''
    & $add "PsGit runs entirely on this machine's local .git store - there is" 'DarkGray'
    & $add "nothing to push or pull. Run 'git status' any time to see where you are." 'DarkGray'
    return $lines.ToArray()
}

function Format-PsGitDiffLine {
    <# .SYNOPSIS Colorize a unified diff string into @{ Text; Color } lines. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$DiffText = '')
    $lines = [System.Collections.Generic.List[object]]::new()
    foreach ($ln in (($DiffText -replace "`r`n", "`n") -split "`n")) {
        $color = if ($ln.StartsWith('@@')) { 'Cyan' }
                 elseif ($ln.StartsWith('+')) { 'Green' }
                 elseif ($ln.StartsWith('-')) { 'Red' }
                 else { 'Gray' }
        $lines.Add(@{ Text = $ln; Color = $color })
    }
    return $lines.ToArray()
}
