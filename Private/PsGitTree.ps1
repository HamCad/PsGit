function ConvertTo-PsGitTree {
    <# .SYNOPSIS Build nested git tree objects from flat index entries; return the root tree id. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath, [object[]]$Entries = @())
    $files = [System.Collections.Generic.List[object]]::new()
    $dirs = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $Entries) {
        Assert-PsGitSafeTreePath -Path $e.Path
        $slash = $e.Path.IndexOf('/')
        if ($slash -lt 0) {
            $files.Add([pscustomobject]@{ Name = $e.Path; Mode = $e.Mode; Id = $e.Id })
        } else {
            $dir = $e.Path.Substring(0, $slash)
            $rest = $e.Path.Substring($slash + 1)
            if (-not $dirs.ContainsKey($dir)) { $dirs[$dir] = [System.Collections.Generic.List[object]]::new() }
            $dirs[$dir].Add([pscustomobject]@{ Path = $rest; Mode = $e.Mode; Id = $e.Id })
        }
    }
    $treeEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $treeEntries.Add([pscustomobject]@{ Name = $f.Name; Mode = $f.Mode; Id = $f.Id; IsDir = $false })
    }
    foreach ($dir in $dirs.Keys) {
        $subId = ConvertTo-PsGitTree -RepoPath $RepoPath -Entries @($dirs[$dir])
        $treeEntries.Add([pscustomobject]@{ Name = $dir; Mode = '40000'; Id = $subId; IsDir = $true })
    }
    $treeEntries.Sort([System.Comparison[object]] {
        param($a, $b)
        $an = if ($a.IsDir) { $a.Name + '/' } else { $a.Name }
        $bn = if ($b.IsDir) { $b.Name + '/' } else { $b.Name }
        [string]::CompareOrdinal($an, $bn)
    })
    $ms = [System.IO.MemoryStream]::new()
    try {
        foreach ($t in $treeEntries) {
            $hdr = [System.Text.Encoding]::UTF8.GetBytes("$($t.Mode) $($t.Name)" + [char]0)
            $ms.Write($hdr, 0, $hdr.Length)
            $sha = New-Object byte[] 20
            for ($k = 0; $k -lt 20; $k++) { $sha[$k] = [Convert]::ToByte($t.Id.Substring($k * 2, 2), 16) }
            $ms.Write($sha, 0, 20)
        }
        $content = $ms.ToArray()
    } finally { $ms.Dispose() }
    return Write-PsGitObject -RepoPath $RepoPath -Type 'tree' -Content $content
}
