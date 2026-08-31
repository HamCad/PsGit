#
# PsGit module manifest.
# A pure-PowerShell, local-only git engine (no git.exe, no remotes/push/fetch/clone) for
# Windows PowerShell 5.1+.
# Import with:  Import-Module PsGit   then run:  git status
#
@{
    RootModule = 'PsGit.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a2f4a1a0-6c9a-4b2b-9b8b-3a6b6a2f4b10'
    Author = 'HamCad'
    Description = 'Pure-PowerShell, local-only git engine for Windows PowerShell 5.1+'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    # Public/*.ps1 is the actual source of truth for what's exported (see PsGit.psm1); '*' just
    # keeps this manifest from silently re-hiding a function that PsGit.psm1 already exports
    # whenever a new file lands in Public/.
    FunctionsToExport = '*'
}
