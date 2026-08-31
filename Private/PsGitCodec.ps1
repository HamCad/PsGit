function Format-PsGitFramedObject {
    <# .SYNOPSIS Frame an object as "<type> <size>\0<content>" bytes (git loose/hash framing). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type, [byte[]]$Content = @())
    $header = [System.Text.Encoding]::ASCII.GetBytes("$Type $($Content.Length)" + [char]0)
    $framed = New-Object byte[] ($header.Length + $Content.Length)
    [Array]::Copy($header, 0, $framed, 0, $header.Length)
    if ($Content.Length) { [Array]::Copy($Content, 0, $framed, $header.Length, $Content.Length) }
    return $framed
}

function Get-PsGitObjectId {
    <# .SYNOPSIS Compute the git SHA-1 object id (40-char lowercase hex) for a type+content. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type, [byte[]]$Content = @())
    $framed = Format-PsGitFramedObject -Type $Type -Content $Content
    $hash = Get-PsGitSHA1Hash -Bytes $framed
    return Get-PsGitHexLower -Bytes $hash
}

function ConvertFrom-PsGitFramed {
    <# .SYNOPSIS Split framed bytes into Type/Size/Content. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Raw)
    $nul = [Array]::IndexOf($Raw, [byte]0)
    if ($nul -lt 0) { throw 'Malformed git object: no NUL header terminator.' }
    $header = [System.Text.Encoding]::ASCII.GetString($Raw, 0, $nul)
    $sp = $header.IndexOf(' ')
    if ($sp -lt 0) { throw "Malformed git object header: '$header'." }
    $type = $header.Substring(0, $sp)
    $size = [int]$header.Substring($sp + 1)
    $content = New-Object byte[] ($Raw.Length - $nul - 1)
    if ($content.Length) { [Array]::Copy($Raw, $nul + 1, $content, 0, $content.Length) }
    return [pscustomobject]@{ Type = $type; Size = $size; Content = $content }
}

function ConvertFrom-PsGitTree {
    <# .SYNOPSIS Parse a tree object's bytes into ordered @{ Mode; Name; Id } entries.
       An empty tree (zero entries) is a legitimate git object - e.g. a commit recording that the
       store had every fact deleted. -Content is intentionally NOT Mandatory: PowerShell's parameter
       binder rejects an explicit zero-length array argument for a Mandatory array-typed parameter
       ("Cannot bind argument to parameter 'Content' because it is an empty array"), which is a
       binder quirk unrelated to this function's own logic - the while loop below already handles a
       0-length array correctly and simply returns zero entries. #>
    [CmdletBinding()]
    param([byte[]]$Content = @())
    $entries = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $Content.Length) {
        $sp = $i
        while ($sp -lt $Content.Length -and $Content[$sp] -ne 0x20) { $sp++ }
        $mode = [System.Text.Encoding]::ASCII.GetString($Content, $i, $sp - $i)
        $nameStart = $sp + 1
        $nul = $nameStart
        while ($nul -lt $Content.Length -and $Content[$nul] -ne 0) { $nul++ }
        $name = [System.Text.Encoding]::UTF8.GetString($Content, $nameStart, $nul - $nameStart)
        $shaStart = $nul + 1
        $id = Get-PsGitHexLower -Bytes $Content -Offset $shaStart -Count 20
        $entries.Add([pscustomobject]@{ Mode = $mode; Name = $name; Id = $id })
        $i = $shaStart + 20
    }
    return $entries.ToArray()
}

function ConvertFrom-PsGitCommit {
    <# .SYNOPSIS Parse a commit object into Tree/Parents/Author/Committer/Message. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Content)
    $text = [System.Text.Encoding]::UTF8.GetString($Content)
    $sep = $text.IndexOf("`n`n")
    $headerText = if ($sep -ge 0) { $text.Substring(0, $sep) } else { $text }
    $message = if ($sep -ge 0) { $text.Substring($sep + 2) } else { '' }
    $tree = $null; $author = $null; $committer = $null
    $parents = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($headerText -split "`n")) {
        if ($line.StartsWith('tree '))           { $tree = $line.Substring(5) }
        elseif ($line.StartsWith('parent '))      { $parents.Add($line.Substring(7)) }
        elseif ($line.StartsWith('author '))      { $author = $line.Substring(7) }
        elseif ($line.StartsWith('committer '))   { $committer = $line.Substring(10) }
    }
    return [pscustomobject]@{
        Tree = $tree; Parents = $parents.ToArray(); Author = $author
        Committer = $committer; Message = $message
    }
}

function ConvertFrom-PsGitIdentity {
    <# .SYNOPSIS Parse a git identity line "Name <email> <epoch> <tz>" into Name/Email/Date. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line)
    $lt = $Line.LastIndexOf('<')
    $gt = $Line.IndexOf('>', $lt)
    $name = $Line.Substring(0, $lt).Trim()
    $email = $Line.Substring($lt + 1, $gt - $lt - 1)
    $rest = $Line.Substring($gt + 1).Trim()
    $bits = $rest.Split(' ')
    $epoch = [long]$bits[0]
    $tz = $bits[1]
    $sign = if ($tz[0] -eq '-') { -1 } else { 1 }
    $offset = [TimeSpan]::FromMinutes($sign * ([int]$tz.Substring(1, 2) * 60 + [int]$tz.Substring(3, 2)))
    $date = [System.DateTimeOffset]::FromUnixTimeSeconds($epoch).ToOffset($offset)
    return [pscustomobject]@{ Name = $name; Email = $email; Date = $date }
}
