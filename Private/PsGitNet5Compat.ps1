function Get-PsGitHexLower {
    <#
    .SYNOPSIS
        PS5.1-compatible replacement for [Convert]::ToHexStringLower(bytes[, offset, count]), which
        does not exist under .NET Framework (added to .NET in the 5/9 timeframe).
    .PARAMETER Bytes
        Source byte array. NOT Mandatory on purpose: PowerShell's parameter binder rejects an
        explicit zero-length array argument for a Mandatory array-typed parameter, and an empty
        id (e.g. hashing zero content) is a legitimate input here - same binder quirk documented
        on ConvertFrom-PsGitTree's -Content.
    .PARAMETER Offset
        Start index within Bytes. Defaults to 0.
    .PARAMETER Count
        Number of bytes to encode. Defaults to the remainder of Bytes from Offset.
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [byte[]]$Bytes = @(),
        [int]$Offset = 0,
        [int]$Count = -1
    )
    if ($Count -lt 0) { $Count = $Bytes.Length - $Offset }
    $sb = [System.Text.StringBuilder]::new($Count * 2)
    $end = $Offset + $Count
    for ($i = $Offset; $i -lt $end; $i++) { [void]$sb.Append($Bytes[$i].ToString('x2')) }
    return $sb.ToString()
}

function Get-PsGitSHA1Hash {
    <#
    .SYNOPSIS
        PS5.1-compatible replacement for [System.Security.Cryptography.SHA1]::HashData(bytes), which
        does not exist under .NET Framework (the static HashData API was added in .NET 5).
    .PARAMETER Bytes
        Bytes to hash.
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure (creates/disposes its own SHA1 instance per call
        - the engine hashes small in-memory buffers, not a hot loop, so a shared/cached instance would
        add complexity for no measurable benefit).
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { return $sha1.ComputeHash($Bytes) } finally { $sha1.Dispose() }
}

if (-not ('PsGit.Adler32' -as [type])) {
    # Compiled once, here, when this file is dot-sourced by PsGit.psm1 at Import-Module time -
    # NOT per Get-PsGitAdler32 call. The '-as [type]' guard is required because the dev loop
    # re-imports with -Force (see tests/*.Tests.ps1, CLAUDE.md), and Add-Type throws
    # "type already exists" on a second load within the same PS process/runspace otherwise.
    Add-Type -Language CSharp -TypeDefinition @'
namespace PsGit
{
    public static class Adler32
    {
        // Same NMAX-block algorithm the old PowerShell loop used, just compiled instead of
        // interpreted - a per-byte PowerShell loop is fine for source/markdown/config blobs but
        // is orders of magnitude too slow at tens-of-MB+ scale (see issue #5).
        public static uint Compute(byte[] bytes)
        {
            const uint MOD = 65521;
            const int NMAX = 5552; // largest n such that 255*n*(n+1)/2 + (n+1)*(MOD-1) <= 2^32-1
            uint a = 1, b = 0;
            int len = bytes.Length;
            int i = 0;
            while (i < len)
            {
                int blockEnd = i + NMAX;
                if (blockEnd > len) { blockEnd = len; }
                for (int k = i; k < blockEnd; k++)
                {
                    a += bytes[k];
                    b += a;
                }
                a %= MOD;
                b %= MOD;
                i = blockEnd;
            }
            return (b << 16) | a;
        }
    }
}
'@
}

function Get-PsGitAdler32 {
    <#
    .SYNOPSIS
        Compute the Adler-32 checksum (RFC 1950 section 8) of a byte array.
    .DESCRIPTION
        .NET has no built-in Adler-32 (it is zlib's trailer checksum, not a .NET Framework primitive
        the way CRC32 nearly is). Needed only because ConvertTo-PsGitZlibBytes below has to
        hand-roll the zlib envelope that ZLibStream (.NET 6+) would otherwise produce.
    .PARAMETER Bytes
        Bytes to checksum (the UNCOMPRESSED content).
    .NOTES
        PowerShell 5.1+. Private (not exported). Pure. Delegates to the Add-Type'd PsGit.Adler32
        C# class above, which is compiled once at module import (see the guard preceding this
        function), not per call - see issue #5 for why the old plain PowerShell loop wasn't enough.
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param([byte[]]$Bytes = @())
    return [PsGit.Adler32]::Compute($Bytes)
}

function ConvertTo-PsGitZlibBytes {
    <#
    .SYNOPSIS
        Zlib-compress bytes (RFC 1950 wrapper around raw DEFLATE) - PS5.1/.NET Framework has
        DeflateStream (raw DEFLATE, RFC 1951) but no ZLibStream (.NET 6+), which adds the 2-byte
        header and 4-byte Adler-32 trailer.
    .PARAMETER Content
        Bytes to compress.
    .NOTES
        PowerShell 5.1+. Private (not exported). The 0x78 0x9C header advertises method=deflate,
        32K window, default flevel; per RFC 1950 the header value only has to satisfy
        (CMF*256+FLG) % 31 == 0 for a reader to accept it; it does not have to describe the encoder's
        actual compression level for the stream to decompress correctly, so a fixed constant is fine
        regardless of DeflateStream's internal choices.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([byte[]]$Content = @())
    $adler = Get-PsGitAdler32 -Bytes $Content
    $ms = [System.IO.MemoryStream]::new()
    try {
        $ms.WriteByte(0x78); $ms.WriteByte(0x9C)
        $ds = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
        try { if ($Content.Length) { $ds.Write($Content, 0, $Content.Length) } } finally { $ds.Dispose() }
        $ms.WriteByte([byte](($adler -shr 24) -band 0xFF))
        $ms.WriteByte([byte](($adler -shr 16) -band 0xFF))
        $ms.WriteByte([byte](($adler -shr 8) -band 0xFF))
        $ms.WriteByte([byte]($adler -band 0xFF))
        return $ms.ToArray()
    } finally { $ms.Dispose() }
}

function Expand-PsGitZlibBytes {
    <#
    .SYNOPSIS
        Zlib-decompress bytes starting at Offset in Buffer; reads to the DEFLATE end-of-stream marker
        (RFC 1951 BFINAL), which is self-terminating - the caller need not know the decompressed size
        up front. The counterpart to ConvertTo-PsGitZlibBytes; together they replace ZLibStream.
    .PARAMETER Buffer
        Source byte array containing a zlib stream (2-byte header + DEFLATE data [+ trailer]).
    .PARAMETER Offset
        Index of the zlib stream's first header byte within Buffer. Defaults to 0.
    .NOTES
        PowerShell 5.1+. Private (not exported). The Adler-32 trailer is NOT verified - the engine
        only ever reads objects it (or a real git client) wrote, and adding verification here would
        require tracking exactly how many bytes DeflateStream consumed to locate the trailer, which
        DeflateStream does not expose. Corruption would already surface as a downstream parse failure
        (bad object framing) or an object-id mismatch.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][byte[]]$Buffer, [int]$Offset = 0)
    $ms = [System.IO.MemoryStream]::new($Buffer, $Offset + 2, $Buffer.Length - $Offset - 2)
    $ds = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $out = [System.IO.MemoryStream]::new()
    try { $ds.CopyTo($out) } finally { $ds.Dispose(); $ms.Dispose() }
    return $out.ToArray()
}
