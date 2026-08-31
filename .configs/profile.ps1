<#
.SYNOPSIS
    PowerShell prompt for use with PsGit: current path, branch, and porcelain status
    counts (added/modified/deleted/untracked), color-coded instead of symbol-decorated.
.DESCRIPTION
    Copy this file to your real profile location and it loads automatically on shell
    start. On Creo that's:

        C:\Users\claude\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1

    Adjust $psGitModulePath below if PsGit lives somewhere other than
    C:\Users\claude\PsGit-test\PsGit.

    Color key: green = added, yellow = modified, red = deleted, gray = untracked.
    Numbers only appear when the count is nonzero, and a clean repo shows no numbers
    at all - the path and branch just sit there in their own colors.
.NOTES
    PowerShell 5.1+.
#>

$psGitModulePath = 'C:\Users\claude\PsGit-test\PsGit\PsGit.psd1'
if (Test-Path -LiteralPath $psGitModulePath) {
    Import-Module $psGitModulePath -Force -ErrorAction SilentlyContinue
}

function prompt {
    $path = $PWD.Path
    if ($path.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = '~' + $path.Substring($HOME.Length)
    }
    Write-Host $path -NoNewline -ForegroundColor Cyan

    if (Get-Command Test-PsGitRepo -ErrorAction SilentlyContinue) {
        try {
            $repo = Test-PsGitRepo -RepoPath $PWD.Path
            if ($repo.IsRepo -and $repo.Supported) {
                $status = Get-PsGitStatus -RepoPath $PWD.Path

                Write-Host " " -NoNewline
                Write-Host $status.Branch -NoNewline -ForegroundColor Magenta

                $added = @($status.Staged | Where-Object State -eq 'added').Count
                $modified = (@($status.Staged | Where-Object State -eq 'modified').Count) +
                            (@($status.Unstaged | Where-Object State -eq 'modified').Count)
                $deleted = (@($status.Staged | Where-Object State -eq 'deleted').Count) +
                           (@($status.Unstaged | Where-Object State -eq 'deleted').Count)
                $untracked = @($status.Untracked).Count

                if ($added) { Write-Host " $added" -NoNewline -ForegroundColor Green }
                if ($modified) { Write-Host " $modified" -NoNewline -ForegroundColor Yellow }
                if ($deleted) { Write-Host " $deleted" -NoNewline -ForegroundColor Red }
                if ($untracked) { Write-Host " $untracked" -NoNewline -ForegroundColor Gray }
            }
        } catch {
            # Never let a broken repo state take the prompt down with it.
        }
    }

    Write-Host ""
    return "> "
}
