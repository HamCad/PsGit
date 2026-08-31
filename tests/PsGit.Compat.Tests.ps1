<#
.SYNOPSIS
    Direct tests of Private/PsGitNet5Compat.ps1 - the PS5.1/.NET Framework replacements for
    three .NET 5/6+-only APIs (ZLibStream, SHA1.HashData, Convert.ToHexStringLower) that don't
    exist under Windows PowerShell 5.1.
.NOTES
    PowerShell 5.1+ / Pester 3.4 (Windows-builtin) syntax: 'Should Be', no BeforeAll/AfterAll
    dependency, no -Output param on Invoke-Pester.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'PsGit.psd1') -Force
. (Join-Path $PSScriptRoot 'Fixture.Helpers.ps1')

Describe 'PsGit compat shim: hex encoding' {
    InModuleScope PsGit {
        It 'encodes a full byte array' {
            $bytes = [byte[]]@(0xDE, 0xAD, 0xBE, 0xEF)
            Get-PsGitHexLower -Bytes $bytes | Should Be 'deadbeef'
        }
        It 'honors Offset and Count' {
            $bytes = [byte[]]@(0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02)
            Get-PsGitHexLower -Bytes $bytes -Offset 1 -Count 3 | Should Be 'adbeef'
        }
        It 'returns empty string for empty input' {
            Get-PsGitHexLower -Bytes ([byte[]]@()) | Should Be ''
        }
    }
}

Describe 'PsGit compat shim: SHA1 + object ids match real git' {
    InModuleScope PsGit {
        It 'matches the known git empty-blob id' {
            $id = Get-PsGitObjectId -Type 'blob' -Content ([byte[]]@())
            $id | Should Be 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'
        }
        It 'matches the known git blob id for "hello`n"' {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("hello`n")
            $id = Get-PsGitObjectId -Type 'blob' -Content $bytes
            $id | Should Be 'ce013625030ba8dba906f756967f9e9ca394464a'
        }
    }
}

Describe 'PsGit compat shim: zlib round-trip (own encoder/decoder)' {
    InModuleScope PsGit {
        # sizes deliberately straddle the Adler-32 NMAX=5552 block boundary used by Get-PsGitAdler32
        $sizes = @(0, 1, 100, 5551, 5552, 5553, 20000)
        foreach ($sz in $sizes) {
            It "round-trips $sz random bytes" {
                $rng = New-Object System.Random(42)
                $content = New-Object byte[] $sz
                $rng.NextBytes($content)
                $compressed = ConvertTo-PsGitZlibBytes -Content $content
                $roundtrip = Expand-PsGitZlibBytes -Buffer $compressed -Offset 0
                $roundtrip.Length | Should Be $content.Length
                $same = $true
                for ($k = 0; $k -lt $content.Length; $k++) { if ($roundtrip[$k] -ne $content[$k]) { $same = $false; break } }
                $same | Should Be $true
            }
        }
    }
}

Describe 'PsGit compat shim: decodes real git-authored zlib objects' {
    # This is the check that matters: PsGitNet5Compat.ps1's Expand-PsGitZlibBytes is built on
    # System.IO.Compression.DeflateStream (raw DEFLATE), not zlib itself - it has to correctly
    # inflate whatever real git's own zlib encoder produced, not just round-trip its own output.
    $fixture = Expand-PsGitTestFixture -Name 'basic'
    $global:PsGitTestFixturePath = $fixture.Path
    $global:PsGitTestManifest = $fixture.Manifest
    try {
        InModuleScope PsGit {
            foreach ($prop in $global:PsGitTestManifest.blob_content_b64.PSObject.Properties) {
                $sha = $prop.Name
                $expectedBytes = [Convert]::FromBase64String($prop.Value)
                $objFile = Join-Path $global:PsGitTestFixturePath ".git\objects\$($sha.Substring(0,2))\$($sha.Substring(2))"

                It "decodes real git loose object $sha ($($expectedBytes.Length) bytes)" {
                    Test-Path -LiteralPath $objFile | Should Be $true
                    $raw = [System.IO.File]::ReadAllBytes($objFile)
                    $decompressed = Expand-PsGitZlibBytes -Buffer $raw -Offset 0
                    $parsed = ConvertFrom-PsGitFramed -Raw $decompressed
                    $parsed.Content.Length | Should Be $expectedBytes.Length
                    $matches = $true
                    for ($k = 0; $k -lt $expectedBytes.Length; $k++) { if ($parsed.Content[$k] -ne $expectedBytes[$k]) { $matches = $false; break } }
                    $matches | Should Be $true
                    # and the id PsGit itself computes from the decoded content must match the filename sha
                    (Get-PsGitObjectId -Type $parsed.Type -Content $parsed.Content) | Should Be $sha
                }
            }
        }
    } finally {
        Remove-PsGitTestFixture -Path $fixture.Path
    }
}
