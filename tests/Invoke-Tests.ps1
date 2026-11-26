<#
.SYNOPSIS
    Runs the whole test suite (Pester 5) and, when installed, PSScriptAnalyzer.

.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1

.EXAMPLE
    pwsh -NoProfile -File ./tests/Invoke-Tests.ps1 -ExcludeTag UI -OutputFile test-results.xml

.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -Tag UI
#>
[CmdletBinding()]
param(
    [string[]]$Tag = @(),
    [string[]]$ExcludeTag = @(),
    [string]$OutputFile
)
$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    throw 'Pester 5.5+ richiesto: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck'
}
Import-Module $pester

$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.Filter.ExcludeTag = $ExcludeTag
if ($Tag.Count) { $configuration.Filter.Tag = $Tag }
if ($OutputFile) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = $OutputFile
}
Invoke-Pester -Configuration $configuration
