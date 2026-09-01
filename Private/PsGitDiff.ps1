if (-not ('PsGit.LineDiff' -as [type])) {
    # Compiled once, here, when this file is dot-sourced by PsGit.psm1 at Import-Module time -
    # NOT per Get-PsGitDiffLine call. Same guard pattern as PsGit.Adler32
    # (Private/PsGitNet5Compat.ps1, issue #5): Add-Type throws "type already exists" on a second
    # load within the same PS process/runspace, which the dev loop's repeated
    # Import-Module -Force otherwise hits.
    Add-Type -Language CSharp -TypeDefinition @'
namespace PsGit
{
    public static class LineDiff
    {
        // Same O(m*n) LCS table-fill + backtrack the old PowerShell nested loops used (including
        // the '-' vs '+' tie-break: prefer delete when the "down" score is >= the "right" score),
        // just compiled instead of interpreted - a per-cell PowerShell loop is fine for small
        // diffs but is orders of magnitude too slow once a file reaches a few thousand lines (see
        // issue #22: ~11.5s for a 3000-line file). Returns the op sequence as one char per line
        // ('=' keep, '-' delete from old, '+' insert from new); the caller reconstructs line text
        // from OldLines/NewLines by walking this string, so behavior - not just speed - is
        // unchanged from the original PowerShell backtrack.
        public static string ComputeOps(string[] oldLines, string[] newLines)
        {
            int m = oldLines.Length, n = newLines.Length;
            int[,] lcs = new int[m + 1, n + 1];
            for (int i = m - 1; i >= 0; i--)
            {
                for (int j = n - 1; j >= 0; j--)
                {
                    if (string.Equals(oldLines[i], newLines[j], System.StringComparison.Ordinal))
                    {
                        lcs[i, j] = lcs[i + 1, j + 1] + 1;
                    }
                    else
                    {
                        int down = lcs[i + 1, j];
                        int right = lcs[i, j + 1];
                        lcs[i, j] = down > right ? down : right;
                    }
                }
            }
            var sb = new System.Text.StringBuilder(m + n);
            int a = 0, b = 0;
            while (a < m && b < n)
            {
                if (string.Equals(oldLines[a], newLines[b], System.StringComparison.Ordinal))
                {
                    sb.Append('='); a++; b++;
                }
                else if (lcs[a + 1, b] >= lcs[a, b + 1]) { sb.Append('-'); a++; }
                else { sb.Append('+'); b++; }
            }
            while (a < m) { sb.Append('-'); a++; }
            while (b < n) { sb.Append('+'); b++; }
            return sb.ToString();
        }
    }
}
'@
}

function Get-PsGitDiffLine {
    <# .SYNOPSIS Unified line diff (LCS shortest edit script) -> hunk lines; @() if identical. #>
    [CmdletBinding()]
    param([string[]]$OldLines = @(), [string[]]$NewLines = @(), [int]$Context = 3)
    # A parameter default only applies when the argument is omitted, not when a caller passes an
    # explicit $null - coerce here so ComputeOps (a direct .NET static call) never dereferences a
    # null array's .Length and dies with a bare NullReferenceException (Gitea #40).
    if ($null -eq $OldLines) { $OldLines = @() }
    if ($null -eq $NewLines) { $NewLines = @() }
    $m = $OldLines.Count; $n = $NewLines.Count
    # LCS table-fill + backtrack happens in compiled C# (PsGit.LineDiff, above) - see issue #22.
    $opsStr = [PsGit.LineDiff]::ComputeOps($OldLines, $NewLines)
    $ops = [System.Collections.Generic.List[object]]::new()
    $i = 0; $j = 0
    foreach ($c in $opsStr.ToCharArray()) {
        switch ($c) {
            '=' { $ops.Add(@{ Op = '='; Text = $OldLines[$i] }); $i++; $j++ }
            '-' { $ops.Add(@{ Op = '-'; Text = $OldLines[$i] }); $i++ }
            '+' { $ops.Add(@{ Op = '+'; Text = $NewLines[$j] }); $j++ }
        }
    }
    if (-not ($ops | Where-Object { $_.Op -ne '=' })) { return @() }

    # group into hunks with up to $Context equal lines around changes
    $out = [System.Collections.Generic.List[string]]::new()
    $k = 0; $count = $ops.Count
    while ($k -lt $count) {
        if ($ops[$k].Op -eq '=') { $k++; continue }
        # start of a change run: include leading context already emitted? Simpler: find run bounds
        $start = $k
        # collect change region extended by trailing context
        $end = $k
        while ($end -lt $count) {
            if ($ops[$end].Op -ne '=') { $end++; continue }
            # allow up to 2*Context consecutive '=' to bridge; else stop
            $run = 0; $t = $end
            while ($t -lt $count -and $ops[$t].Op -eq '=') { $run++; $t++ }
            if ($run -le ($Context * 2) -and $t -lt $count) { $end = $t } else { break }
        }
        $hunkStart = [Math]::Max(0, $start - $Context)
        $hunkEnd = [Math]::Min($count, $end + $Context)
        $oStart = 1; $nStart = 1; $oCount = 0; $nCount = 0
        for ($z = 0; $z -lt $hunkStart; $z++) { if ($ops[$z].Op -ne '+') { $oStart++ }; if ($ops[$z].Op -ne '-') { $nStart++ } }
        $body = [System.Collections.Generic.List[string]]::new()
        for ($z = $hunkStart; $z -lt $hunkEnd; $z++) {
            switch ($ops[$z].Op) {
                '=' { $body.Add(' ' + $ops[$z].Text); $oCount++; $nCount++ }
                '-' { $body.Add('-' + $ops[$z].Text); $oCount++ }
                '+' { $body.Add('+' + $ops[$z].Text); $nCount++ }
            }
        }
        $out.Add("@@ -$oStart,$oCount +$nStart,$nCount @@")
        foreach ($b in $body) { $out.Add($b) }
        $k = $hunkEnd
    }
    return $out.ToArray()
}
