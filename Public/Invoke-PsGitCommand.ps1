function Invoke-PsGitCommand {
    <#
    .SYNOPSIS
        Drives the pure-PowerShell, local-only git engine (init/status/log/diff/add/commit/branch/
        checkout/restore/reset/help) against a working directory - no git.exe, no remotes, no
        push/fetch/clone.
    .DESCRIPTION
        Ported from PowerGenAI's in-chat /git command. That original took its subcommand line from a
        chat REPL and its output/prompt/commit-message-drafting from PowerGenAI's provider and TUI
        plumbing (Write-GenAIOutput, Read-GenAIPrompt, Invoke-GenAIBuildCall); none of that exists
        standalone, so this version reads git subcommands directly, writes with Write-Host, prompts
        with Read-Host, and always asks the caller for a commit message (-Message, or an interactive
        prompt) rather than drafting one - there is no AI integration in this module.

        Prefer the `git` function for interactive use - it takes native, space-separated arguments
        the way real git does (`git commit -m "msg"`) and delegates here. This one still takes its
        whole subcommand line as a single string and remains for callers that already build that
        string themselves.
    .PARAMETER CommandInput
        The subcommand and its arguments, e.g. 'status', 'commit -m "msg"', 'log 5', 'add .'.
    .PARAMETER RepoPath
        Working-tree root to operate on. Defaults to the current location.
    .EXAMPLE
        Invoke-PsGitCommand 'status'
    .EXAMPLE
        Invoke-PsGitCommand 'commit -m "initial commit"'
    .NOTES
        PowerShell 5.1+. Exported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$CommandInput,
        [string]$RepoPath = (Get-Location).Path
    )

    $arg = ([string]$CommandInput).Trim()
    $sub = if ($arg) { ($arg -split '\s+', 2)[0].ToLowerInvariant() } else { 'status' }
    if ($sub -in @('-h', '--help')) { $sub = 'help' }
    $rest = if ($arg -and $arg -match '\s') { ($arg -split '\s+', 2)[1] } else { '' }
    if ($sub -eq 'unstage') { $sub = 'restore'; $rest = ('--staged ' + $rest).Trim() }
    $repo = $RepoPath

    if ($sub -notin @('init', 'help') -and -not (Test-PsGitRepo -RepoPath $repo).IsRepo) {
        Write-Host "`n* Not a git repository - run 'git init'`n" -ForegroundColor Yellow
        return
    }

    try {
    switch ($sub) {
        'init' {
            Initialize-PsGitRepo -RepoPath $repo
            Write-Host "`n* Initialized empty Git repository in $repo`n" -ForegroundColor Green
        }
        'status' {
            $st = Get-PsGitStatus -RepoPath $repo
            if ($rest.Trim() -eq '--porcelain') {
                foreach ($ln in (Format-PsGitStatusPorcelain -Status $st)) { Write-Host $ln }
            } else {
                Write-Host ''
                foreach ($ln in (Format-PsGitStatusLine -Status $st)) { Write-Host $ln.Text -ForegroundColor $ln.Color }
                Write-Host ''
            }
        }
        'log' {
            $max = 15
            if ($rest.Trim() -match '^\d+$') { $max = [int]$rest.Trim() }
            $commits = @(Get-PsGitLog -RepoPath $repo -Max $max)
            Write-Host ''
            foreach ($ln in (Format-PsGitLogLine -Commits $commits)) { Write-Host $ln.Text -ForegroundColor $ln.Color }
            Write-Host ''
        }
        'diff' {
            $target = $rest.Trim().Trim('"')
            $paths = if ($target) { @($target) } else {
                $st = Get-PsGitStatus -RepoPath $repo
                @($st.Unstaged | ForEach-Object Path)
            }
            if ($paths.Count -eq 0) { Write-Host "`n* No changes to diff`n" -ForegroundColor DarkGray; break }
            foreach ($p in $paths) {
                $d = Get-PsGitDiff -RepoPath $repo -Path $p
                if ([string]::IsNullOrEmpty($d)) { continue }
                Write-Host "--- $p" -ForegroundColor Cyan
                foreach ($ln in (Format-PsGitDiffLine -DiffText $d)) { Write-Host $ln.Text -ForegroundColor $ln.Color }
            }
        }
        'add' {
            $spec = $rest.Trim()
            if (-not $spec) { Write-Host "`n* Usage: git add <path...> | .`n" -ForegroundColor Yellow; break }
            $paths = if ($spec -eq '.') { @(Get-PsGitWorkingFile -RepoPath $repo) } else { @(ConvertTo-PsGitArgTokens -Text $spec) }
            if ($paths.Count -eq 0) { Write-Host "`n* Nothing to add`n" -ForegroundColor DarkGray; break }
            Add-PsGitFile -RepoPath $repo -Path $paths
            Write-Host "`n* Staged $($paths.Count) file(s)`n" -ForegroundColor Green
        }
        'commit' {
            $msg = $null
            if ($rest -match '(?s)-m\s+(.+)$') { $msg = $Matches[1].Trim().Trim('"') }
            if (-not $msg) {
                $diff = Get-PsGitStagedDiff -RepoPath $repo
                if ([string]::IsNullOrWhiteSpace($diff)) {
                    Write-Host "`n* Nothing staged to commit (use git add)`n" -ForegroundColor Yellow
                    break
                }
                $msg = (Read-Host -Prompt 'Commit message').Trim()
                if (-not $msg) { Write-Host "`n* Commit cancelled (empty message)`n" -ForegroundColor Yellow; break }
            }
            $name = if ($env:USERNAME) { $env:USERNAME } else { 'PsGit' }
            $id = New-PsGitCommit -RepoPath $repo -Message $msg -Name $name -Email "$name@localhost"
            Write-Host "`n* Committed $($id.Substring(0,7)): $msg`n" -ForegroundColor Green
        }
        'branch' {
            $tokens = @($rest.Trim() -split '\s+' | Where-Object { $_ })
            if ($tokens.Count -eq 0) {
                foreach ($b in (Get-PsGitBranch -RepoPath $repo)) {
                    $mark = if ($b.IsCurrent) { '*' } else { ' ' }
                    Write-Host "$mark $($b.Name)" -ForegroundColor ($(if ($b.IsCurrent) { 'Green' } else { 'Gray' }))
                }
            } elseif ($tokens[0] -eq 'new' -and $tokens.Count -eq 2) {
                New-PsGitBranch -RepoPath $repo -Name $tokens[1]
                Write-Host "`n* Created branch $($tokens[1])`n" -ForegroundColor Green
            } elseif ($tokens[0] -eq 'rm' -and $tokens.Count -ge 2) {
                $name = $tokens[1]
                $force = $tokens.Count -gt 2 -and @(($tokens[2..($tokens.Count - 1)]) -match '^(-f|--force|-D)$').Count -gt 0
                # Mirrors real git's 'branch -d' (refuses an unmerged branch) vs. 'branch -D'
                # (this -f/--force/-D) - see #12. Remove-PsGitBranch throws on refusal, caught by
                # this function's outer try/catch like every other engine error here.
                Remove-PsGitBranch -RepoPath $repo -Name $name -Force:$force
                Write-Host "`n* Deleted branch $name`n" -ForegroundColor Yellow
            } else {
                Write-Host "`n* Usage: git branch [new <name> | rm <name> [-f|--force|-D]]`n" -ForegroundColor Yellow
            }
        }
        'restore' {
            $tokens = @(ConvertTo-PsGitArgTokens -Text $rest)
            $staged = $false
            if ($tokens -contains '--staged' -or $tokens -contains '-S') {
                $staged = $true
                $tokens = @($tokens | Where-Object { $_ -ne '--staged' -and $_ -ne '-S' })
            }
            if ($tokens.Count -eq 0) {
                Write-Host "`n* Usage: git restore [--staged] <path...> | .`n" -ForegroundColor Yellow
                break
            }
            $st = Get-PsGitStatus -RepoPath $repo
            $paths = if ($tokens.Count -eq 1 -and $tokens[0] -eq '.') {
                if ($staged) { @($st.Staged | ForEach-Object Path) } else { @($st.Unstaged | ForEach-Object Path) }
            } else { $tokens }
            if ($paths.Count -eq 0) { Write-Host "`n* Nothing to restore`n" -ForegroundColor DarkGray; break }
            if ($staged) {
                Restore-PsGitIndexFile -RepoPath $repo -Path $paths
                Write-Host "`n* Unstaged $($paths.Count) file(s)`n" -ForegroundColor Green
            } else {
                Restore-PsGitWorktreeFile -RepoPath $repo -Path $paths
                Write-Host "`n* Restored $($paths.Count) file(s)`n" -ForegroundColor Green
            }
        }
        'reset' {
            $tokens = @($rest.Trim() -split '\s+' | Where-Object { $_ })
            if ($tokens -contains '--hard') {
                $head = Get-PsGitHead -RepoPath $repo
                if (-not $head.Id) { Write-Host "`n* Nothing to reset (no commits yet)`n" -ForegroundColor Yellow; break }
                $st = Get-PsGitStatus -RepoPath $repo
                $dirty = (@($st.Staged).Count + @($st.Unstaged).Count) -gt 0
                if ($dirty) {
                    $ans = Read-Host -Prompt 'This discards ALL staged and unstaged changes. Continue? (y/N)'
                    if ($ans -notmatch '^(y|yes)$') { Write-Host "`n* Reset aborted`n" -ForegroundColor Yellow; break }
                }
                # Restore-PsGitTree reconciles both the index and the working tree against HEAD in
                # one pass - exactly what a hard reset is. -Force carries through the dirty-check
                # this case already did above, same pattern checkout uses for its own prompt.
                Restore-PsGitTree -RepoPath $repo -Id $head.Id -Force
                Write-Host "`n* HEAD is now at $($head.Id.Substring(0,7)) (index and working tree reset)`n" -ForegroundColor Green
            } else {
                $paths = @($tokens | Where-Object { $_ -ne '.' -and $_ -ne '--mixed' })
                Restore-PsGitIndexFile -RepoPath $repo -Path $paths
                if ($paths.Count -eq 0) { Write-Host "`n* Unstaged all changes`n" -ForegroundColor Green }
                else { Write-Host "`n* Unstaged $($paths.Count) file(s)`n" -ForegroundColor Green }
            }
        }
        'checkout' {
            $parts = @($rest.Trim() -split '\s+' | Where-Object { $_ })
            if ($parts.Count -eq 0) { Write-Host "`n* Usage: git checkout <branch|commit> | -b <new-branch> [<start-point>]`n" -ForegroundColor Yellow; break }
            if ($parts[0] -eq '-b') {
                if ($parts.Count -lt 2) { Write-Host "`n* Usage: git checkout -b <new-branch> [<start-point>]`n" -ForegroundColor Yellow; break }
                $newName = $parts[1]
                $startPoint = if ($parts.Count -ge 3) { $parts[2] } else { $null }
                $startId = $null
                if ($startPoint) {
                    $startId = Get-PsGitRef -RepoPath $repo -Name "refs/heads/$startPoint"
                    if (-not $startId) { $startId = try { Resolve-PsGitId -RepoPath $repo -Id $startPoint } catch { $null } }
                    if (-not $startId) { Write-Host "`n* Unknown ref '$startPoint'`n" -ForegroundColor Red; break }
                }
                # New-PsGitBranch throws (caught by this function's outer try/catch) if $newName
                # already exists - mirrors real git's `checkout -b` refusing to clobber a branch.
                New-PsGitBranch -RepoPath $repo -Name $newName -StartId $startId
                $parts = @($newName)
            }
            $refName = $parts[0]
            $branchId = Get-PsGitRef -RepoPath $repo -Name "refs/heads/$refName"
            $targetId = if ($branchId) {
                $branchId
            } else {
                try { Resolve-PsGitId -RepoPath $repo -Id $refName } catch { $null }
            }
            if (-not $targetId) { Write-Host "`n* Unknown ref '$refName'`n" -ForegroundColor Red; break }
            $prevHead = Get-PsGitHead -RepoPath $repo
            $st = Get-PsGitStatus -RepoPath $repo
            $dirty = (@($st.Staged).Count + @($st.Unstaged).Count + @($st.Untracked).Count) -gt 0
            if ($dirty) {
                $ans = Read-Host -Prompt 'Working tree has changes; checkout may overwrite files. Continue? (y/N)'
                if ($ans -notmatch '^(y|yes)$') { Write-Host "`n* Checkout aborted`n" -ForegroundColor Yellow; break }
            }
            # Restore-PsGitTree does its own precise per-file conflict check and refuses by
            # default (see #8); the blanket "anything changed anywhere?" prompt above is the
            # user's confirmation for this interactive path, so -Force carries it through instead
            # of making the user answer the same question twice in different words.
            Restore-PsGitTree -RepoPath $repo -Id $targetId -Force
            if ($branchId) {
                [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "ref: refs/heads/$refName`n")
            } else {
                [System.IO.File]::WriteAllText((Join-Path $repo '.git\HEAD'), "$targetId`n")
            }
            $prevName = if ($prevHead.Symbolic) { $prevHead.Ref -replace '^refs/heads/', '' } else { $prevHead.Id }
            Add-PsGitReflogEntry -RepoPath $repo -RefName 'HEAD' -OldId $prevHead.Id -NewId $targetId -Message "checkout: moving from $prevName to $refName"
            Write-Host "`n* Checked out $refName`n" -ForegroundColor Green
        }
        'help' {
            Write-Host ''
            foreach ($ln in (Format-PsGitHelpLine)) { Write-Host $ln.Text -ForegroundColor $ln.Color }
            Write-Host ''
        }
        default {
            Write-Host "`n* Unknown subcommand '$sub' - try 'git help'`n" -ForegroundColor Red
        }
    }
    }
    catch {
        Write-Host "`n* git: $($_.Exception.Message)`n" -ForegroundColor Red
        return
    }
}
