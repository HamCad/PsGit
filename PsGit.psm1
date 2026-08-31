<#
.SYNOPSIS
    PsGit module loader.
.DESCRIPTION
    Dot-sources every Private then Public *.ps1 file and exports the Public functions. Ported from
    PowerGenAI's pure-PowerShell git engine (no git.exe, no remotes - init/status/log/diff/add/
    commit/branch/checkout only), adapted to run under Windows PowerShell 5.1 / .NET Framework:
    see Private/PsGitNet5Compat.ps1 for the three .NET 5/6+ APIs (ZLibStream, SHA1.HashData,
    Convert.ToHexStringLower) that don't exist there and what replaces them.
.NOTES
    PowerShell 5.1+. Imported via the PsGit.psd1 manifest.
#>

$private = Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1"
foreach ($file in $private) { . $file.FullName }

$public = Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"
foreach ($file in $public) { . $file.FullName }

Export-ModuleMember -Function $public.BaseName
