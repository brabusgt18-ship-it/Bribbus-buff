# Backups written by v2.0 must stay readable and restorable by this version, and journals written
# by this version must stay readable by v2.0 (safe downgrade). The v2.0 envelope functions are
# loaded straight from archive/v2.0 so the test always uses the original implementation.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $legacySource = Join-Path (Join-Path (Join-Path $script:RepoRoot 'archive') 'v2.0') 'BrabusDebloater.ps1'
    $source = [IO.File]::ReadAllText($legacySource).Replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'S-1-5-21-1000-TEST'")
    $parsed = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    foreach ($name in 'BackupHash', 'WriteEnvelope', 'ReadEnvelope', 'NewPayload') {
        $function = $parsed.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
}

Describe 'Backup compatibility with v2.0' {
    BeforeEach {
        $root = Reset-TestState
        $adapter = 'NET|' + [guid]::NewGuid()
        $plan = "POWER|$($script:FakeScheme)|54533251-82be-4824-96c1-47b60b740d00"
        $batch = [guid]::NewGuid().ToString('N')
        $userRecords = @(
            [pscustomobject]@{ Name = 'Registry'; Path = 'Software\BrabusCompat'; Key = 'A'; Old = [pscustomobject]@{ Exists = $false; Kind = ''; Value = $null }; Target = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = 1 }; BatchId = $batch; Id = [guid]::NewGuid().ToString('N'); Time = (Get-Date).AddHours(-2).ToString('o') },
            [pscustomobject]@{ Name = 'Power'; Path = $plan; Key = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Old = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = 80 }; Target = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = 100 }; BatchId = $batch; Id = [guid]::NewGuid().ToString('N'); Time = (Get-Date).AddHours(-1).ToString('o') }
        )
        $networkRecords = @(
            [pscustomobject]@{ Name = 'Driver'; Path = $adapter; Key = '*EEE'; Old = [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = '1' }; Target = [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = '0' }; BatchId = $batch; Id = [guid]::NewGuid().ToString('N'); Time = (Get-Date).ToString('o') }
        )
        # Exactly what v2.0 SaveJournal writes: primary, mirror, initialized flag.
        $userPayload = NewPayload $userRecords 'Journal'
        WriteEnvelope $script:UserJournal.Primary $userPayload
        WriteEnvelope $script:UserJournal.Mirror $userPayload
        [IO.File]::WriteAllText($script:UserJournal.Flag, '2')
        $networkPayload = NewPayload $networkRecords 'Journal'
        WriteEnvelope $script:NetworkJournal.Primary $networkPayload
        WriteEnvelope $script:NetworkJournal.Mirror $networkPayload
        [IO.File]::WriteAllText($script:NetworkJournal.Flag, '2')
        # Live values as v2.0 left them.
        Set-FakeValue -Path 'Software\BrabusCompat' -Key 'A' -Value 1
        $script:FakePower["$plan|bc5038f7-23e0-4960-96da-33abaf5935ec"] = 100
        $script:FakeNetwork["$adapter|*EEE"] = '0'
    }
    AfterEach { Remove-TestState $root }

    It 'flags v2.0 copies that diverge (different payloads in primary and mirror)' {
        $other = NewPayload @() 'Journal'
        Start-Sleep -Milliseconds 20
        WriteEnvelope $script:UserJournal.Mirror $other
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 2
        $script:UserJournal.Warning | Should -Match 'divergenti'
    }

    It 'reads v2.0 journals without warnings' {
        @(Read-Journal -Journal $script:UserJournal).Count | Should -Be 2
        $script:UserJournal.Warning | Should -BeNullOrEmpty
        @(Read-Journal -Journal $script:NetworkJournal).Count | Should -Be 1
    }

    It 'audits and restores every v2.0 record' {
        @(Get-ReleaseAudit | Where-Object { $_.State -eq 'VALORE VERIFICATO' -or $_.State -eq 'RIAVVIO NECESSARIO' }).Count | Should -Be 3
        $result = Invoke-RestoreBatch -Items (@(Read-Journal -Journal $script:UserJournal) + @(Read-Journal -Journal $script:NetworkJournal))
        $result.OK | Should -Be 3
        (Get-TweakValue -Path 'Software\BrabusCompat' -Key 'A').Exists | Should -BeFalse
        $script:FakePower.Values | Should -Contain 80
        $script:FakeNetwork.Values | Should -Contain '1'
    }

    It 'writes journals that v2.0 can still read (safe downgrade)' {
        $null = Invoke-ApplyBatch -Items @(New-TestItem -Name 'New' -Path 'Software\BrabusCompat' -Key 'B' -Value 3)
        $legacyView = ReadEnvelope $script:UserJournal.Primary
        @($legacyView.Records).Count | Should -Be 3
        $null = ReadEnvelope $script:UserJournal.Mirror
        (@($legacyView.Records) | Where-Object Key -EQ 'B').Target.Value | Should -Be 3
    }

    It 'shares one BatchId per apply, which v2.0 snapshots also carry' {
        $items = @(New-TestItem -Name 'C' -Path 'Software\BrabusCompat' -Key 'C'), (New-TestItem -Name 'D' -Path 'Software\BrabusCompat' -Key 'D')
        $null = Invoke-ApplyBatch -Items $items
        $snapshot = Get-ChildItem -LiteralPath $script:Paths.BackupDir -Filter 'snapshot-*.json' | Select-Object -First 1
        @((ReadEnvelope $snapshot.FullName).Records).Count | Should -Be 2
    }
}
