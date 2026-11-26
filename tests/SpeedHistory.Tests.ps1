BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Speed history' {
    BeforeEach { $root = Reset-TestState }
    AfterEach { Remove-TestState $root }

    It 'persists finished tests once, newest first, and keeps partial results separate' {
        $state = @{ TestId = 'test1'; Stage = 'COMPLETATO'; Elapsed = 26.5; Down = 100; Up = 20; Ping = 30; Jitter = 4; Loss = 0; NetworkConfig = 'testA'; Method = 'm' }
        Save-SpeedResult -State $state
        Save-SpeedResult -State $state
        $state.TestId = 'test2'; $state.Down = 110; $state.NetworkConfig = 'testB'
        Save-SpeedResult -State $state
        $state.TestId = 'partial'; $state.Stage = 'PARZIALE'; $state.Up = $null
        Save-SpeedResult -State $state
        $rows = @(Read-SpeedHistory)
        $rows.Count | Should -Be 3
        $rows[0].Id | Should -Be 'partial'
        $rows[0].Status | Should -Be 'Parziale / limite'
        $rows[1].Status | Should -Be 'Completo'
        Get-SpeedComparison -Rows $rows | Should -Match '\+10[,.]00'
        Get-SpeedComparison -Rows $rows | Should -Match 'configurazione rilevata diversa'
    }

    It 'ignores tests that never finished' {
        Save-SpeedResult -State @{ TestId = 'x'; Stage = 'DOWNLOAD | 3 / 14 s'; Elapsed = $null }
        @(Read-SpeedHistory).Count | Should -Be 0
    }

    It 'asks for two comparable complete tests before comparing' {
        Get-SpeedComparison -Rows @() | Should -Match 'Servono due test'
        Get-SpeedComparison -Rows @([pscustomobject]@{ Status = 'Completo'; Method = 'a'; Down = 1; Up = 1 }, [pscustomobject]@{ Status = 'Completo'; Method = 'b'; Down = 1; Up = 1 }) | Should -Match 'Servono due test'
    }

    It 'refuses to overwrite a history file with an unknown format' {
        Set-Content -LiteralPath $script:Paths.SpeedHistory -Value '{"Format":"Other","Version":1,"Results":[]}'
        { Read-SpeedHistory } | Should -Throw '*Formato*'
    }
}

Describe 'Time handling' {
    It 'normalizes ISO strings and DateTime values to the same UTC instant' {
        $now = Get-Date
        (ConvertTo-UtcTime $now.ToString('o')) | Should -Be $now.ToUniversalTime()
        (ConvertTo-UtcTime $now) | Should -Be $now.ToUniversalTime()
        (ConvertTo-UtcTime ([datetimeoffset]$now)) | Should -Be $now.ToUniversalTime()
    }
}

Describe 'Atomic files' {
    BeforeEach { $root = Reset-TestState }
    AfterEach { Remove-TestState $root }

    It 'writes JSON with a BOM that every older version can read, replacing in place' {
        $file = Join-Path $root 'report.json'
        Save-JsonFile -Path $file -InputObject @{ A = 1 }
        Save-JsonFile -Path $file -InputObject @{ A = 2 }
        $bytes = [IO.File]::ReadAllBytes($file)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        (Read-JsonFile -Path $file).A | Should -Be 2
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp*').Count | Should -Be 0
    }

    It 'resolves relative paths against the PowerShell location (v2.0 used the process directory)' {
        Push-Location $root
        try {
            Save-JsonFile -Path 'relative.json' -InputObject @{ A = 1 }
            Test-Path -LiteralPath (Join-Path $root 'relative.json') | Should -BeTrue
        } finally {
            Pop-Location
        }
    }
}
