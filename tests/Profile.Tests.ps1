BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function New-ProfileRow {
        param([string]$Path, [string]$Key, [string]$Kind, $Value, [string]$Category = 'Test')
        [pscustomobject]@{
            Path = $Path; Key = $Key; Category = $Category; Name = $Key; Selected = $true; CanApply = $true; CanRestore = $false
            Status = $script:StatusAvailable; TargetState = (New-ValueState -Exists $true -Kind $Kind -Value $Value)
        }
    }
}

Describe 'Portable profiles (ported from v2.0 Test-Profile.ps1)' {
    BeforeEach {
        $source = @(
            (New-ProfileRow 'POWER|source-plan|subgroup' 'setting' 'DWord' 100 'Power / CPU'),
            (New-ProfileRow 'NET|source-adapter' '*RSS' 'String' '1' 'Network'),
            (New-ProfileRow 'Software\BrabusTest' 'Example' 'DWord' 0),
            (New-ProfileRow 'Software\Personal' 'PrivateApp' 'DWord' 1 'App Notifications')
        )
        $destination = @(
            (New-ProfileRow 'POWER|other-plan|subgroup' 'setting' 'DWord' 100 'Power / CPU'),
            (New-ProfileRow 'NET|other-adapter' '*RSS' 'String' '1' 'Network'),
            (New-ProfileRow 'Software\BrabusTest' 'Example' 'DWord' 0)
        )
        $document = New-PortableProfile -General @($source[0], $source[2], $source[3]) -Network @($source[1]) -SelectedOnly
    }

    It 'excludes private categories and contains only opaque identifiers' {
        $document.Selections.Count | Should -Be 3
        $document.Selections | ForEach-Object { $_ | Should -Match '^T-[A-F0-9]{32}$' }
        ($document | ConvertTo-Json) | Should -Not -Match 'source-adapter|source-plan|BrabusTest'
    }

    It 'matches power plans and adapters on another PC' {
        $result = Resolve-PortableProfile -Document $document -General @($destination[0], $destination[2]) -Network @($destination[1])
        $result.Eligible.Count | Should -Be 3
        $result.Unknown | Should -Be 0
        $result.Ambiguous | Should -Be 0
    }

    It 'blocks changed targets and ambiguous adapters' {
        $changed = New-ProfileRow 'Software\BrabusTest' 'Example' 'DWord' 1
        $duplicate = New-ProfileRow 'NET|second-adapter' '*RSS' 'String' '1' 'Network'
        $result = Resolve-PortableProfile -Document $document -General @($destination[0], $changed) -Network @($destination[1], $duplicate)
        $result.Eligible.Count | Should -Be 1
        $result.Unknown | Should -Be 1
        $result.Ambiguous | Should -Be 1
    }

    It 'imports legacy v1 profiles' {
        $legacy = @{ Format = 'BrabusPreset'; Version = 1; Selections = @((Get-LegacyProfileId $destination[2])) }
        (Resolve-PortableProfile -Document $legacy -General @($destination[2]) -Network @()).Eligible.Count | Should -Be 1
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'arbitrary text identifiers'; Document = @{ Format = 'BrabusPreset'; Version = 2; Selections = @('Write-Host arbitrary') } }
        @{ Case = 'unknown formats'; Document = @{ Format = 'Other'; Version = 2; Selections = @() } }
        @{ Case = 'unknown versions'; Document = @{ Format = 'BrabusPreset'; Version = 9; Selections = @() } }
        @{ Case = 'oversized profiles'; Document = @{ Format = 'BrabusPreset'; Version = 2; Selections = @(1..2001 | ForEach-Object { 'T-' + ('{0:X32}' -f $_) }) } }
    ) {
        param($Case, $Document)
        { Resolve-PortableProfile -Document $Document -General @() -Network @() } | Should -Throw
    }

    It 'preserves pending selections safely across a refresh' {
        $map = Get-SelectionMap $destination
        $destination[0].CanApply = $false
        $destination[0].CanRestore = $true
        Restore-SelectionMap -Rows $destination -Map $map
        $destination[0].Selected | Should -BeFalse
        $destination[1].Selected | Should -BeTrue
        $destination[2].Selected | Should -BeTrue
    }

    It 'exports only targets that are currently configured' {
        $root = Reset-TestState
        try {
            Set-FakeValue -Path 'Software\BrabusTest' -Key 'Example' -Value 0
            $configured = New-ProfileRow 'Software\BrabusTest' 'Example' 'DWord' 0
            $missing = New-ProfileRow 'Software\BrabusTest' 'Other' 'DWord' 0
            (New-PortableProfile -General @($configured, $missing) -Network @()).Selections.Count | Should -Be 1
        } finally {
            Remove-TestState $root
        }
    }
}
