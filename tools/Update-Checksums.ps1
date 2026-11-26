<#
.SYNOPSIS
    Regenerates SHA256SUMS.txt for the release files, or verifies it with -Verify.

.EXAMPLE
    powershell.exe -NoProfile -File .\tools\Update-Checksums.ps1

.EXAMPLE
    pwsh -NoProfile -File ./tools/Update-Checksums.ps1 -Verify
#>
[CmdletBinding()]
param([switch]$Verify)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @('BrabusDebloater.ps1', 'README.md', 'CHANGELOG.md')
$sums = Join-Path $root 'SHA256SUMS.txt'
$lines = foreach ($file in $files) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $root $file) -Algorithm SHA256).Hash, $file
}
$expected = ($lines -join "`r`n") + "`r`n"

if ($Verify) {
    $actual = [IO.File]::ReadAllText($sums)
    if ($actual -cne $expected) {
        throw "SHA256SUMS.txt non aggiornato. Atteso:`n$expected`nEseguire tools/Update-Checksums.ps1"
    }
    'SHA256SUMS.txt OK'
} else {
    [IO.File]::WriteAllText($sums, $expected, (New-Object Text.UTF8Encoding($false)))
    $expected
}
