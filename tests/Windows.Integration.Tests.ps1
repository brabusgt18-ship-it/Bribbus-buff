# Windows-only checks against the REAL registry, power plans and GUI. Every change happens on an
# isolated HKCU test key, a temporary power-plan clone or a temporary state folder, and is removed.
# Skipped automatically on other platforms. Run on Windows PowerShell 5.1 (and optionally pwsh).

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

BeforeAll {
    $script:Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'BrabusDebloater.ps1'
    $script:Shell = if ($PSVersionTable.PSEdition -eq 'Desktop') { Join-Path $PSHOME 'powershell.exe' } else { Join-Path $PSHOME 'pwsh.exe' }

    function Invoke-ScriptProcess {
        <# Runs the tool in a child process with its own LOCALAPPDATA, returns exit code and output. #>
        param([string[]]$Arguments)
        $state = Join-Path ([IO.Path]::GetTempPath()) ('BrabusProc-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $state
        $saved = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $state
            $output = & $script:Shell -NoProfile -STA -ExecutionPolicy Bypass -File $script:Script @Arguments 2>&1 | ForEach-Object { [string]$_ }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
        } finally {
            $env:LOCALAPPDATA = $saved
            Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Real registry backup engine' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        . $script:Script
        Initialize-NativeInterop
        $script:IsAdmin = Test-IsAdministrator
    }
    BeforeEach {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('BrabusReal-' + [guid]::NewGuid().ToString('N'))
        Initialize-AppState -Root $root
        $key = 'Software\BrabusPester-' + [guid]::NewGuid().ToString('N')
    }
    AfterEach {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($key, $false)
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'applies, verifies and restores DWord and String values on an isolated key' {
        $context = [pscustomobject]@{ Build = 99999; IsDomainJoined = $false }
        $dword = ConvertTo-TweakRow -Context $context -Definition @{ Name = 'D'; Category = 'Test'; Path = $key; Key = 'D'; Value = 1; Note = 'x' }
        $string = ConvertTo-TweakRow -Context $context -Definition @{ Name = 'S'; Category = 'Test'; Kind = 'String'; Path = $key; Key = 'S'; Value = '150'; Note = 'x' }
        (Invoke-ApplyBatch -Items @($dword, $string)).OK | Should -Be 2
        (Get-TweakValue -Path $key -Key 'D').Kind | Should -Be 'DWord'
        (Get-TweakValue -Path $key -Key 'S').Value | Should -Be '150'
        (Invoke-RestoreBatch -Items @($dword, $string)).OK | Should -Be 2
        (Get-TweakValue -Path $key -Key 'D').Exists | Should -BeFalse
        (Get-TweakValue -Path $key -Key 'S').Exists | Should -BeFalse
    }

    It 'detects that a normal HKCU key is writable' {
        Test-UserRegistryWritable -Path "$key\Missing\Deeper" | Should -BeTrue
    }

    It 'detects that HKCU\Software\Policies is read-only for a standard user' {
        if ($script:IsAdmin) { Set-ItResult -Skipped -Because 'elevated session: policy keys are writable'; return }
        Test-UserRegistryWritable -Path 'Software\Policies\BrabusPesterProbe' | Should -BeFalse
    }
}

Describe 'Power plan rollback on a temporary clone' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        . $script:Script
        Initialize-NativeInterop
    }

    It 'writes and restores every offered AC power setting without changing the active plan' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('BrabusPower-' + [guid]::NewGuid().ToString('N'))
        Initialize-AppState -Root $root
        $active = Get-ActivePowerScheme
        $rows = @(Get-PowerTweakRow -Context (Get-SystemContext))
        if (-not $rows.Count) { Set-ItResult -Skipped -Because 'power tweaks are offered only on desktops running on AC'; return }
        $clone = [guid]::NewGuid().ToString()
        $created = $false
        try {
            $null = Invoke-PowerCfg -ArgumentList @('/duplicatescheme', $active, $clone)
            $created = $true
            $records = @()
            $batch = [guid]::NewGuid().ToString('N')
            foreach ($row in $rows) {
                $item = [pscustomobject]@{ Name = $row.Name; Path = $row.Path.Replace($active, $clone); Key = $row.Key; TargetState = $row.TargetState }
                $records += New-BackupRecord -Item $item -Old (Get-TweakValue -Path $item.Path -Key $item.Key) -BatchId $batch
                Save-Journal -Journal $script:UserJournal -Records $records
                Set-TweakValue -Path $item.Path -Key $item.Key -State $item.TargetState
                Test-SameState (Get-TweakValue -Path $item.Path -Key $item.Key) $item.TargetState | Should -BeTrue
            }
            Restore-AllUserTweak
            foreach ($record in $records) { Test-SameState (Get-TweakValue -Path $record.Path -Key $record.Key) $record.Old | Should -BeTrue }
            Get-ActivePowerScheme | Should -Be $active
        } finally {
            if ($created -and (Get-ActivePowerScheme) -ne $clone) { $null = Invoke-PowerCfg -ArgumentList @('/delete', $clone) }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Command-line modes in a child process' -Skip:(-not $script:OnWindows) {
    It 'passes -SelfTest' {
        $result = Invoke-ScriptProcess -Arguments @('-SelfTest')
        $result.Output | Should -Match 'PASS registry test keys'
        $result.ExitCode | Should -Be 0
    }

    It 'prints a valid -ReleaseCheck summary' {
        $result = Invoke-ScriptProcess -Arguments @('-ReleaseCheck')
        $result.ExitCode | Should -Be 0
        $summary = $result.Output | ConvertFrom-Json
        $summary.General | Should -BeGreaterThan 0
    }

    It 'passes the automated GUI test (-UiTest)' -Tag 'UI' {
        $result = Invoke-ScriptProcess -Arguments @('-UiTest')
        $result.Output | Should -Match 'UI TEST OK'
        $result.ExitCode | Should -Be 0
    }
}
