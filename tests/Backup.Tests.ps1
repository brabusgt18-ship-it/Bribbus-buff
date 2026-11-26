BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Backup envelope' {
    BeforeEach { $root = Reset-TestState }
    AfterEach { Remove-TestState $root }

    It 'round-trips a payload with Unicode text and verifies the checksum' {
        $file = Join-Path $root 'envelope.json'
        $unicode = 'Caf' + [char]0xE9 + ' ' + [char]0x2013 + ' impostazione'
        $record = [pscustomobject]@{ Name = $unicode; Path = 'Software\X'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'DWord' 1); BatchId = 'b'; Id = 'i'; Time = (Get-Date).ToString('o') }
        Write-BackupEnvelope -File $file -Payload (New-BackupPayload -Records @($record) -Type 'Journal')
        $payload = Read-BackupEnvelope -File $file
        $payload.Records[0].Name | Should -Be $unicode
        $payload.Owner | Should -Be 'S-1-5-21-1000-TEST'
    }

    It 'rejects a tampered payload' {
        $file = Join-Path $root 'envelope.json'
        Write-BackupEnvelope -File $file -Payload (New-BackupPayload -Records @() -Type 'Journal')
        $text = [IO.File]::ReadAllText($file).Replace('Journal', 'Journax')
        [IO.File]::WriteAllText($file, $text)
        { Read-BackupEnvelope -File $file } | Should -Throw '*Checksum*'
    }

    It 'rejects a backup that belongs to another user' {
        $file = Join-Path $root 'envelope.json'
        $payload = New-BackupPayload -Records @() -Type 'Journal'
        $payload.Owner = 'S-1-5-21-OTHER'
        Write-BackupEnvelope -File $file -Payload $payload
        { Read-BackupEnvelope -File $file } | Should -Throw '*altro utente*'
    }

    It 'leaves no temporary files behind' {
        Write-BackupEnvelope -File (Join-Path $root 'a.json') -Payload (New-BackupPayload -Records @() -Type 'Journal')
        Write-BackupEnvelope -File (Join-Path $root 'a.json') -Payload (New-BackupPayload -Records @() -Type 'Journal')
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp*').Count | Should -Be 0
    }
}

Describe 'Record validation' {
    BeforeAll { $null = Reset-TestState }

    It 'accepts registry, power and network records' {
        $records = @(
            [pscustomobject]@{ Name = 'r'; Path = 'Software\X'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'DWord' 1); BatchId = 'b'; Id = '1' },
            [pscustomobject]@{ Name = 'p'; Path = "POWER|$([guid]::NewGuid())|$([guid]::NewGuid())"; Key = [guid]::NewGuid().ToString(); Old = (New-ValueState $true 'DWord' 5); Target = (New-ValueState $true 'DWord' 100); BatchId = 'b'; Id = '2' },
            [pscustomobject]@{ Name = 'n'; Path = "NET|$([guid]::NewGuid())"; Key = '*RSS'; Old = (New-ValueState $true 'String' '0'); Target = (New-ValueState $true 'String' '1'); BatchId = 'b'; Id = '3' }
        )
        { Assert-BackupRecord $records } | Should -Not -Throw
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'paths outside HKCU roots' }
        @{ Case = 'unsupported kinds' }
        @{ Case = 'non-whitelisted network keywords' }
        @{ Case = 'non-numeric network values' }
        @{ Case = 'incomplete records' }
    ) {
        param($Case)
        $adapter = "NET|$([guid]::NewGuid())"
        $record = switch ($Case) {
            'paths outside HKCU roots' { [pscustomobject]@{ Name = 'x'; Path = 'HKLM\Software'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'DWord' 1); BatchId = 'b'; Id = '1' } }
            'unsupported kinds' { [pscustomobject]@{ Name = 'x'; Path = 'Software\X'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'Binary' 1); BatchId = 'b'; Id = '1' } }
            'non-whitelisted network keywords' { [pscustomobject]@{ Name = 'x'; Path = $adapter; Key = '*Evil'; Old = (New-ValueState $true 'String' '0'); Target = (New-ValueState $true 'String' '1'); BatchId = 'b'; Id = '1' } }
            'non-numeric network values' { [pscustomobject]@{ Name = 'x'; Path = $adapter; Key = '*RSS'; Old = (New-ValueState $true 'String' '0'); Target = (New-ValueState $true 'String' 'calc.exe'); BatchId = 'b'; Id = '1' } }
            'incomplete records' { [pscustomobject]@{ Name = 'x'; Path = 'Software\X'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'DWord' 1); BatchId = ''; Id = '1' } }
        }
        { Assert-BackupRecord @($record) } | Should -Throw
    }

    It 'rejects duplicate Path+Key records' {
        $one = [pscustomobject]@{ Name = 'x'; Path = 'Software\X'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'DWord' 1); BatchId = 'b'; Id = '1' }
        $two = [pscustomobject]@{ Name = 'y'; Path = 'Software\X'; Key = 'A'; Old = (New-ValueState); Target = (New-ValueState $true 'DWord' 2); BatchId = 'b'; Id = '2' }
        { Assert-BackupRecord @($one, $two) } | Should -Throw '*duplicato*'
    }
}

Describe 'Apply and restore (ported from v2.0 Test-Backup.ps1)' {
    BeforeEach { $root = Reset-TestState }
    AfterEach { Remove-TestState $root }

    It 'snapshots before applying and writes the journal ahead of the value' {
        $a = New-TestItem -Name 'A' -Key 'A' -Value 1
        $b = New-TestItem -Name 'B' -Key 'B' -Value 2
        $batch = New-BackupSnapshot -Journal $script:UserJournal -Items @($a, $b)
        @($batch.Records).Count | Should -Be 2
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 0
        Set-Tweak -Item $a -Batch $batch
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
        (Get-TweakValue -Path $b.Path -Key 'B').Exists | Should -BeFalse
        Restore-AllUserTweak
        (Get-TweakValue -Path $a.Path -Key 'A').Exists | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Paths.BackupDir -Filter 'snapshot-*.json').Count | Should -Be 1
    }

    It 'restores selectively and keeps unrelated changes' {
        $a = New-TestItem -Name 'A' -Key 'A' -Value 1
        $b = New-TestItem -Name 'B' -Key 'B' -Value 2
        $result = Invoke-ApplyBatch -Items @($a, $b)
        $result.OK | Should -Be 2
        $records = @(Read-Journal -Journal $script:UserJournal)
        $records[0].BatchId | Should -Be $records[1].BatchId
        Restore-JournalRecordStrict -Journal $script:UserJournal -Id @($records[0].Id)
        (Get-TweakValue -Path $a.Path -Key 'A').Exists | Should -BeFalse
        (Get-TweakValue -Path $b.Path -Key 'B').Value | Should -Be 2
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
    }

    It 'falls back to the mirror when the primary copy is corrupt, then repairs it' {
        $a = New-TestItem -Name 'A' -Key 'A'
        $c = New-TestItem -Name 'C' -Key 'C'
        $null = Invoke-ApplyBatch -Items @($a)
        [IO.File]::WriteAllText($script:UserJournal.Primary, 'corrupt')
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
        $script:UserJournal.Warning | Should -Match 'primaria'
        $null = Invoke-ApplyBatch -Items @($c)
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 2
        { Read-BackupEnvelope -File $script:UserJournal.Primary } | Should -Not -Throw
        $script:UserJournal.Warning | Should -BeNullOrEmpty
    }

    It 'never overwrites a value changed externally and keeps its backup' {
        $b = New-TestItem -Name 'B' -Key 'B' -Value 2
        $null = Invoke-ApplyBatch -Items @($b)
        Set-FakeValue -Path $b.Path -Key 'B' -Value 99
        { Restore-AllUserTweak } | Should -Throw '*non ripristinate*'
        (Get-TweakValue -Path $b.Path -Key 'B').Value | Should -Be 99
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
    }

    It 'blocks every write when both journal copies are corrupt' {
        $a = New-TestItem -Name 'A' -Key 'A'
        $b = New-TestItem -Name 'B' -Key 'B'
        $null = Invoke-ApplyBatch -Items @($a)
        [IO.File]::WriteAllText($script:UserJournal.Primary, 'broken')
        [IO.File]::WriteAllText($script:UserJournal.Mirror, 'broken')
        $result = Invoke-ApplyBatch -Items @($b)
        $result.Failed | Should -Be 1
        (Get-TweakValue -Path $b.Path -Key 'B').Exists | Should -BeFalse
    }

    It 'blocks writes when both copies disappear after initialization' {
        $a = New-TestItem -Name 'A' -Key 'A'
        $null = Invoke-ApplyBatch -Items @($a)
        Remove-Item -LiteralPath $script:UserJournal.Primary, $script:UserJournal.Mirror
        { Read-Journal -Journal $script:UserJournal } | Should -Throw '*mancanti*'
    }

    It 'treats an already configured value as success without a backup' {
        Set-FakeValue -Path 'Software\BrabusPester' -Key 'Same' -Value 1
        $item = New-TestItem -Name 'Same' -Key 'Same' -Value 1
        $result = Invoke-ApplyBatch -Items @($item)
        $result.OK | Should -Be 1
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 0
    }

    It 'refuses to re-apply a row that already has an active backup' {
        $a = New-TestItem -Name 'A' -Key 'A' -Value 1
        $null = Invoke-ApplyBatch -Items @($a)
        Set-FakeValue -Path $a.Path -Key 'A' -Value 7
        $again = New-TestItem -Name 'A' -Key 'A' -Value 1
        $result = Invoke-ApplyBatch -Items @($again)
        $result.Failed | Should -Be 1
        $result.Errors[0] | Should -Match 'Backup gia'
    }

    It 'restores a deleted value (Run entry) to its original string' {
        $run = 'Software\Microsoft\Windows\CurrentVersion\Run'
        Set-FakeValue -Path $run -Key 'Steam' -Kind 'String' -Value '"C:\Steam\steam.exe" -silent'
        $row = @(Get-StartupTweakRow)[0]
        $row.Status | Should -Be $script:StatusAvailable
        (Invoke-ApplyBatch -Items @($row)).OK | Should -Be 1
        (Get-TweakValue -Path $run -Key 'Steam').Exists | Should -BeFalse
        Restore-AllUserTweak
        (Get-TweakValue -Path $run -Key 'Steam').Value | Should -Be '"C:\Steam\steam.exe" -silent'
    }

    It 'migrates a v1 undo.json into the mirrored journal and restores it' {
        $path = 'Software\BrabusPester'
        $old = Get-TweakValue -Path $path -Key 'A'
        $target = New-ValueState $true 'DWord' 1
        ConvertTo-Json -InputObject @([pscustomobject]@{ Name = 'Legacy'; Path = $path; Key = 'A'; Old = $old; Target = $target }) -Depth 8 |
            Set-Content -LiteralPath $script:UserJournal.Legacy -Encoding UTF8
        Set-UserRegistryValue -Path $path -Key 'A' -State $target
        { Read-Journal -Journal $script:UserJournal } | Should -Throw '*non migrato*'
        Invoke-LegacyMigration -Journal $script:UserJournal
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
        Test-Path -LiteralPath $script:UserJournal.Legacy | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Paths.BackupDir -Filter 'legacy-*.json').Count | Should -Be 2
        Restore-AllUserTweak
        (Get-TweakValue -Path $path -Key 'A').Exists | Should -BeFalse
    }

    It 'migrates a v1 undo.json that contains a single record' {
        $target = New-ValueState $true 'DWord' 1
        ConvertTo-Json -InputObject ([pscustomobject]@{ Name = 'Only'; Path = 'Software\BrabusPester'; Key = 'Only'; Old = (New-ValueState); Target = $target }) -Depth 8 |
            Set-Content -LiteralPath $script:UserJournal.Legacy -Encoding UTF8
        Invoke-LegacyMigration -Journal $script:UserJournal
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
    }
}

Describe 'Network journal isolation and mixed batches (ported from Test-Batch / Test-NetworkBackup)' {
    BeforeEach {
        $root = Reset-TestState
        $script:AdapterPath = 'NET|' + [guid]::NewGuid()
        $script:FakeNetwork["$($script:AdapterPath)|*InterruptModeration"] = '1'
        $script:FakeNetwork["$($script:AdapterPath)|*LsoV2IPv4"] = '0'
        $script:FakeNetwork["$($script:AdapterPath)|*LsoV2IPv6"] = '0'
    }
    AfterEach { Remove-TestState $root }

    It 'applies registry and driver rows together, each in its own mirrored journal, and restores a subset' {
        $registry = @(foreach ($name in 'A', 'B', 'C') { New-TestItem -Name $name -Key $name -Value 1 })
        $network = @(foreach ($key in '*InterruptModeration', '*LsoV2IPv4', '*LsoV2IPv6') {
                $target = if ($key -eq '*InterruptModeration') { '0' } else { '1' }
                [pscustomobject]@{ Name = $key; Path = $script:AdapterPath; Key = $key; Category = 'Network'; Status = $script:StatusAvailable; TargetState = (New-ValueState $true 'String' $target) }
            })
        $result = Invoke-ApplyBatch -Items (@($registry) + @($network))
        $result.OK | Should -Be 6
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 3
        @(Read-Journal -Journal $script:NetworkJournal).Count | Should -Be 3
        Test-Path -LiteralPath (Join-Path $script:Paths.BackupDir 'network-active.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Paths.BackupDir 'network-mirror.json') | Should -BeTrue

        foreach ($row in @($registry) + @($network)) {
            $records = @(Read-Journal -Journal (Get-JournalFor -Path $row.Path))
            $row.Status = $script:StatusConfigured
            $row | Add-Member -NotePropertyName VerifiedStatus -NotePropertyValue (Get-VerificationLabel -Row $row -Records $records) -Force
            Set-RowActionFlag -Row $row -Records $records -Valid $true
            $row.CanRestore | Should -BeTrue
            $row.CanApply | Should -BeFalse
        }

        $restore = Invoke-RestoreBatch -Items @($registry[0], $registry[2], $network[0], $network[2])
        $restore.OK | Should -Be 4
        (Get-TweakValue -Path $registry[0].Path -Key 'A').Exists | Should -BeFalse
        (Get-TweakValue -Path $registry[1].Path -Key 'B').Value | Should -Be 1
        $script:FakeNetwork["$($script:AdapterPath)|*InterruptModeration"] | Should -Be '1'
        $script:FakeNetwork["$($script:AdapterPath)|*LsoV2IPv4"] | Should -Be '1'
        $script:FakeNetwork["$($script:AdapterPath)|*LsoV2IPv6"] | Should -Be '0'
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 1
        @(Read-Journal -Journal $script:NetworkJournal).Count | Should -Be 1

        $rest = Invoke-RestoreBatch -Items @($registry[1], $network[1])
        $rest.OK | Should -Be 2
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 0
        @(Read-Journal -Journal $script:NetworkJournal).Count | Should -Be 0
    }

    It 'writes one restore-attempt file per journal, not one per row' {
        $registry = @(foreach ($name in 'A', 'B', 'C', 'D') { New-TestItem -Name $name -Key $name -Value 1 })
        $null = Invoke-ApplyBatch -Items $registry
        $null = Invoke-RestoreBatch -Items $registry
        @(Get-ChildItem -LiteralPath $script:Paths.BackupDir -Filter 'restore-*.json').Count | Should -Be 1
    }

    It 'reports a missing backup instead of failing silently' {
        $row = New-TestItem -Name 'Missing' -Key 'Missing'
        $result = Invoke-RestoreBatch -Items @($row)
        $result.Failed | Should -Be 1
        $result.Errors[0] | Should -Match 'assente'
    }
}

Describe 'Verification labels (ported from Test-Verification.ps1)' {
    BeforeEach { $root = Reset-TestState }
    AfterEach { Remove-TestState $root }

    It 'tracks readback, external drift and restore for registry rows' {
        $row = New-TestItem -Name 'Temporary test' -Key 'Test' -Value 1
        $null = Invoke-ApplyBatch -Items @($row)
        Get-VerificationLabel -Row $row -Records @(Read-Journal -Journal $script:UserJournal) | Should -Be $script:Label.Verified
        Set-FakeValue -Path $row.Path -Key 'Test' -Value 2
        Get-VerificationLabel -Row $row -Records @(Read-Journal -Journal $script:UserJournal) | Should -Be $script:Label.Drift
        Set-FakeValue -Path $row.Path -Key 'Test' -Value 1
        Restore-AllUserTweak
        Get-VerificationLabel -Row $row -Records @(Read-Journal -Journal $script:UserJournal) | Should -Be $script:StatusAvailable
    }

    It 'reports driver rows as pending until a reboot after the change' {
        $path = 'NET|' + [guid]::NewGuid()
        $script:FakeNetwork["$path|*InterruptModeration"] = '1'
        $row = [pscustomobject]@{ Name = 'Mock adapter'; Path = $path; Key = '*InterruptModeration'; Category = 'Network'; Status = $script:StatusAvailable; TargetState = (New-ValueState $true 'String' '0') }
        $null = Invoke-ApplyBatch -Items @($row)
        $records = @(Read-Journal -Journal $script:NetworkJournal)
        Get-VerificationLabel -Row $row -Records $records -Boot (Get-Date).AddDays(-1) | Should -Be $script:Label.RebootPending
        Get-VerificationLabel -Row $row -Records $records -Boot (Get-Date).AddDays(1) | Should -Be $script:Label.RebootVerified
        $script:FakeNetwork["$path|*InterruptModeration"] = '1'
        Get-VerificationLabel -Row $row -Records $records | Should -Be $script:Label.Original
        $script:FakeNetwork["$path|*InterruptModeration"] = '2'
        Get-VerificationLabel -Row $row -Records $records | Should -Be $script:Label.Drift
    }

    It 'marks rows under protected policy keys as needing admin instead of applicable' {
        $row = New-TestItem -Name 'Policy' -Path 'Software\Policies\Microsoft\Edge' -Key 'BackgroundModeEnabled' -Value 0
        $script:FakeUnwritable['Software\Policies\Microsoft\Edge'] = $true
        Set-VerificationState -Rows @($row)
        $row.CanApply | Should -BeFalse
        $row.CanSelect | Should -BeFalse
        $row.VerifiedStatus | Should -Be $script:Label.NeedsAdmin
        $row.SelectionHint | Should -Match 'amministratore'
    }

    It 'lets an elevated session apply protected policy keys' {
        $row = New-TestItem -Name 'Policy' -Path 'Software\Policies\Microsoft\Edge' -Key 'BackgroundModeEnabled' -Value 0
        $script:FakeUnwritable['Software\Policies\Microsoft\Edge'] = $true
        $script:IsAdmin = $true
        Set-VerificationState -Rows @($row)
        $row.CanApply | Should -BeTrue
    }

    It 'flags every row as invalid when the journal cannot be read' {
        $row = New-TestItem -Name 'X' -Key 'X'
        $null = Invoke-ApplyBatch -Items @(New-TestItem -Name 'Y' -Key 'Y')
        [IO.File]::WriteAllText($script:UserJournal.Primary, 'x')
        [IO.File]::WriteAllText($script:UserJournal.Mirror, 'x')
        Set-VerificationState -Rows @($row)
        $row.VerifiedStatus | Should -Be $script:Label.InvalidBackup
        $row.CanSelect | Should -BeFalse
    }
}

Describe 'Integrity audit' {
    BeforeEach { $root = Reset-TestState }
    AfterEach { Remove-TestState $root }

    It 'reports verified, original and conflicting records' {
        $rows = @(foreach ($name in 'A', 'B', 'C') { New-TestItem -Name $name -Key $name -Value 1 })
        $null = Invoke-ApplyBatch -Items $rows
        Set-UserRegistryValue -Path $rows[1].Path -Key 'B' -State (New-ValueState)
        Set-FakeValue -Path $rows[2].Path -Key 'C' -Value 5
        $audit = @(Get-ReleaseAudit)
        ($audit | Where-Object Name -EQ 'A').State | Should -Be 'VALORE VERIFICATO'
        ($audit | Where-Object Name -EQ 'B').State | Should -Be 'VALORE ORIGINALE'
        ($audit | Where-Object Name -EQ 'C').State | Should -Be 'CONFLITTO'
        ($audit | Where-Object Name -EQ 'Backup Utente / energia').State | Should -Be 'LEGGIBILE'
    }
}
