BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Static tweak definitions' {
    BeforeAll {
        $definitions = @(Get-StaticTweakDefinition)
        $categories = @('Gaming', 'Debloat', 'Privacy', 'Visual', 'Explorer', 'Notifications', 'Audio', 'Input', 'Taskbar', 'App Privacy')
    }

    It 'has a unique Path+Key for every definition' {
        $duplicates = @($definitions | Group-Object { ('{0}|{1}' -f $_.Path, $_.Key).ToUpperInvariant() } | Where-Object Count -GT 1)
        $duplicates.Name | Should -BeNullOrEmpty
    }

    It 'uses only known fields, categories, levels and kinds' {
        $fields = @('Name', 'Category', 'Path', 'Key', 'Value', 'Level', 'Note', 'Kind', 'MinBuild', 'ExistingOnly', 'AllowedBefore', 'PersonalOnly')
        foreach ($definition in $definitions) {
            @($definition.Keys | Where-Object { $_ -notin $fields }) | Should -BeNullOrEmpty -Because $definition.Name
            $definition.Category | Should -BeIn $categories -Because $definition.Name
            if ($definition.Level) { $definition.Level | Should -BeIn @('Safe', 'Gaming', 'OptIn') }
            if ($definition.Kind) { $definition.Kind | Should -BeIn @('DWord', 'String') }
            $definition.Name | Should -Not -BeNullOrEmpty
            $definition.Note | Should -Not -BeNullOrEmpty
        }
    }

    It 'stays inside the HKCU roots accepted by the backup validator' {
        foreach ($definition in $definitions) {
            $definition.Path | Should -Match $script:AllowedRecordPath -Because $definition.Name
        }
    }

    It 'keeps DWord values numeric and string values as strings' {
        foreach ($definition in $definitions) {
            if ($definition.Kind -eq 'String') { $definition.Value | Should -BeOfType [string] } else { { [int]$definition.Value } | Should -Not -Throw }
        }
    }

    It 'never offers microphone, camera or accessibility permissions' {
        @($definitions | Where-Object { $_.Path -match 'ConsentStore\\(microphone|webcam|accessibility)' }) | Should -BeNullOrEmpty
    }
}

Describe 'Catalog builder rules' {
    BeforeEach {
        $root = Reset-TestState
        $context = [pscustomobject]@{ Build = 19045; IsDomainJoined = $false }
    }
    AfterEach { Remove-TestState $root }

    It 'creates a missing DWord value and reports it as available' {
        $row = ConvertTo-TweakRow -Context $context -Definition @{ Name = 'n'; Category = 'Visual'; Path = 'Software\T'; Key = 'K'; Value = 0; Note = 'x' }
        $row.Status | Should -Be $script:StatusAvailable
        $row.Before | Should -Be 'Non impostato'
        $row.Level | Should -Be 'OptIn'
    }

    It 'reports an equal value as already configured' {
        Set-FakeValue -Path 'Software\T' -Key 'K' -Value 0
        (ConvertTo-TweakRow -Context $context -Definition @{ Name = 'n'; Category = 'Visual'; Path = 'Software\T'; Key = 'K'; Value = 0; Note = 'x' }).Status | Should -Be $script:StatusConfigured
    }

    It 'never touches a value stored with a different registry type' {
        Set-FakeValue -Path 'Software\T' -Key 'K' -Kind 'String' -Value '0'
        ConvertTo-TweakRow -Context $context -Definition @{ Name = 'n'; Category = 'Visual'; Path = 'Software\T'; Key = 'K'; Value = 0; Note = 'x' } | Should -BeNullOrEmpty
    }

    It 'skips ExistingOnly definitions when Windows has not created the value' {
        ConvertTo-TweakRow -Context $context -Definition @{ Name = 'n'; Category = 'Visual'; Path = 'Software\T'; Key = 'K'; Value = 0; ExistingOnly = $true; Note = 'x' } | Should -BeNullOrEmpty
    }

    It 'skips definitions that need a newer Windows build' {
        ConvertTo-TweakRow -Context $context -Definition @{ Name = 'n'; Category = 'Visual'; Path = 'Software\T'; Key = 'K'; Value = 0; MinBuild = 22000; Note = 'x' } | Should -BeNullOrEmpty
    }

    It 'skips personal-only definitions on domain-joined PCs' {
        $domain = [pscustomobject]@{ Build = 22631; IsDomainJoined = $true }
        ConvertTo-TweakRow -Context $domain -Definition @{ Name = 'n'; Category = 'App Privacy'; Path = 'Software\T'; Key = 'K'; Value = 0; PersonalOnly = $true; Note = 'x' } | Should -BeNullOrEmpty
    }

    It 'requires one of the AllowedBefore values' {
        $definition = @{ Name = 'n'; Category = 'App Privacy'; Kind = 'String'; Path = 'Software\T'; Key = 'Value'; Value = 'Deny'; ExistingOnly = $true; AllowedBefore = @('Allow', 'Deny'); Note = 'x' }
        Set-FakeValue -Path 'Software\T' -Key 'Value' -Kind 'String' -Value 'Prompt'
        ConvertTo-TweakRow -Context $context -Definition $definition | Should -BeNullOrEmpty
        Set-FakeValue -Path 'Software\T' -Key 'Value' -Kind 'String' -Value 'Allow'
        (ConvertTo-TweakRow -Context $context -Definition $definition).Status | Should -Be $script:StatusAvailable
    }

    It 'builds the full catalog without duplicates and with a PWU rating on every row' {
        $catalog = @(Get-TweakCatalog)
        # Empty registry: every definition that may create its value appears exactly once.
        $catalog.Count | Should -Be @(Get-StaticTweakDefinition | Where-Object { -not $_.ExistingOnly }).Count
        @($catalog | Group-Object { ('{0}|{1}' -f $_.Path, $_.Key).ToUpperInvariant() } | Where-Object Count -GT 1) | Should -BeNullOrEmpty
        @($catalog | Where-Object { $_.PWU -notin @('Low', 'Medium', 'High') -or -not $_.PWUReason }) | Should -BeNullOrEmpty
    }

    It 'offers power rows only on desktops running on AC' {
        $script:FakePower["POWER|$($script:FakeScheme)|54533251-82be-4824-96c1-47b60b740d00|bc5038f7-23e0-4960-96da-33abaf5935ec"] = 80
        @(Get-TweakCatalog | Where-Object Category -EQ 'Power / CPU').Count | Should -Be 1
        $script:SystemContext.IsDesktopOnAc = $false
        @(Get-TweakCatalog | Where-Object Category -EQ 'Power / CPU').Count | Should -Be 0
    }

    It 'keeps scanning when one definition cannot be read' {
        function Get-UserRegistryValue {
            param([string]$Path, [string]$Key)
            if ($Key -eq 'AutoGameModeEnabled') { throw 'Accesso negato' }
            New-ValueState
        }
        $catalog = @(Get-TweakCatalog)
        @($catalog | Where-Object Key -EQ 'AutoGameModeEnabled') | Should -BeNullOrEmpty
        $catalog.Count | Should -Be (@(Get-StaticTweakDefinition | Where-Object { -not $_.ExistingOnly }).Count - 1)
    }

    It 'lists notifications of known apps but never security or update toasts' {
        $script:FakeSubKeys['Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'] = @('Discord', 'Windows.SystemToast.SecurityAndMaintenance', 'Microsoft.Windows.Defender.Steam', 'Contoso.App')
        $names = @(Get-AppNotificationTweakRow -Context $context | ForEach-Object Name)
        $names | Should -Be @('Notifiche app: Discord')
    }

    It 'offers removal only for Run entries of allowed launchers, and keeps managed ones restorable' {
        $run = 'Software\Microsoft\Windows\CurrentVersion\Run'
        Set-FakeValue -Path $run -Key 'Steam' -Kind 'String' -Value 'steam.exe'
        Set-FakeValue -Path $run -Key 'SecurityHealth' -Kind 'String' -Value 'x.exe'
        $managed = [pscustomobject]@{ Path = $run; Key = 'Discord'; Target = (New-ValueState) }
        $rows = @(Get-StartupTweakRow -Records @($managed))
        ($rows | ForEach-Object Key) | Should -Be @('Discord', 'Steam')
        ($rows | Where-Object Key -EQ 'Discord').Status | Should -Be $script:StatusConfigured
    }
}

Describe 'ADMX policies' {
    BeforeAll {
        # TestHelpers stubs Get-AdmxUserPolicy: load the real implementation for this block only.
        $parsed = [Management.Automation.Language.Parser]::ParseFile($script:ScriptUnderTest, [ref]$null, [ref]$null)
        $real = $parsed.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AdmxUserPolicy' }, $true)
        . ([scriptblock]::Create($real.Extent.Text))
        $savedWindir = $env:windir
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('BrabusAdmx-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'PolicyDefinitions') -Force
        $xml = '<?xml version="1.0" encoding="utf-8"?><policyDefinitions xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions"><policies>' +
        '<policy name="TaskbarNoThumbnail" class="Both" key="Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" valueName="TaskbarNoThumbnail"><enabledValue><decimal value="1" /></enabledValue></policy>' +
        '<policy name="NoBalloonFeatureAdvertisements" class="Machine" key="Software\Policies\X" valueName="Y"><enabledValue><decimal value="1" /></enabledValue></policy>' +
        '</policies></policyDefinitions>'
        Set-Content -LiteralPath (Join-Path $fixture 'PolicyDefinitions\Taskbar.admx') -Value $xml
        $env:windir = $fixture
    }
    AfterAll {
        $env:windir = $savedWindir
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }

    It 'reads key, value name and enabled value from the template' {
        Reset-SessionCache -All
        $policy = Get-AdmxUserPolicy -File 'Taskbar.admx' -Name 'TaskbarNoThumbnail' -Class @('User', 'Both')
        $policy.Key | Should -Be 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
        $policy.Value | Should -Be 1
    }

    It 'ignores machine policies and missing templates' {
        Get-AdmxUserPolicy -File 'Taskbar.admx' -Name 'NoBalloonFeatureAdvertisements' -Class @('User', 'Both') | Should -BeNullOrEmpty
        Get-AdmxUserPolicy -File 'Missing.admx' -Name 'X' | Should -BeNullOrEmpty
    }

    It 'parses each template only once per session' {
        Reset-SessionCache -All
        $null = Get-AdmxUserPolicy -File 'Taskbar.admx' -Name 'TaskbarNoThumbnail' -Class @('Both')
        Set-Content -LiteralPath (Join-Path $env:windir 'PolicyDefinitions\Taskbar.admx') -Value 'not xml any more'
        (Get-AdmxUserPolicy -File 'Taskbar.admx' -Name 'TaskbarNoThumbnail' -Class @('Both')).Value | Should -Be 1
    }
}

Describe 'PWU rating' {
    It 'rates <Case> as <Expected>' -TestCases @(
        @{ Case = 'a CPU cap at 60%'; Row = @{ Category = 'Power / CPU'; Path = 'POWER|a|b'; Key = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Before = '60' }; Expected = 'High' }
        @{ Case = 'a CPU cap already at 100%'; Row = @{ Category = 'Power / CPU'; Path = 'POWER|a|b'; Key = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Before = '100' }; Expected = 'Medium' }
        @{ Case = 'a startup entry'; Row = @{ Category = 'Startup'; Path = 'Software\Run'; Key = 'Steam' }; Expected = 'Medium' }
        @{ Case = 'background capture'; Row = @{ Category = 'Gaming'; Path = 'Software\X'; Key = 'AppCaptureEnabled' }; Expected = 'Medium' }
        @{ Case = 'a visual preference'; Row = @{ Category = 'Visual'; Path = 'Software\X'; Key = 'TaskbarAl' }; Expected = 'Low' }
    ) {
        param($Case, $Row, $Expected)
        (Get-PwuRating -Row ([pscustomobject]$Row)).Label | Should -Be $Expected
    }
}

Describe 'Network catalog' {
    BeforeEach {
        $root = Reset-TestState
        function Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet'; Status = 'Up'; InterfaceGuid = '{11111111-2222-3333-4444-555555555555}' }
            [pscustomobject]@{ Name = 'Wi-Fi'; Status = 'Disconnected'; InterfaceGuid = '{66666666-2222-3333-4444-555555555555}' }
        }
        function Get-NetAdapterAdvancedProperty {
            [pscustomobject]@{ RegistryKeyword = '*InterruptModeration'; RegistryValue = @('1'); ValidRegistryValues = @('0', '1') }
            [pscustomobject]@{ RegistryKeyword = '*RSS'; RegistryValue = @('1'); ValidRegistryValues = @('0', '1') }
            [pscustomobject]@{ RegistryKeyword = '*EEE'; RegistryValue = @('1'); ValidRegistryValues = @('1') }
            [pscustomobject]@{ RegistryKeyword = '*SelectiveSuspend'; RegistryValue = @('1'); ValidRegistryValues = @('0', '1') }
            [pscustomobject]@{ RegistryKeyword = '*SpeedDuplex'; RegistryValue = @('0'); ValidRegistryValues = @('0', '6') }
        }
    }
    AfterEach { Remove-TestState $root }

    It 'lists only whitelisted keywords of adapters that are up and support the target' {
        $rows = @(Get-NetworkTweakRow)
        ($rows | ForEach-Object Key | Sort-Object) | Should -Be @('*InterruptModeration', '*RSS', '*SelectiveSuspend')
        ($rows | Where-Object Key -EQ '*RSS').Status | Should -Be $script:StatusConfigured
        ($rows | Where-Object Key -EQ '*InterruptModeration').Path | Should -Be 'NET|11111111-2222-3333-4444-555555555555'
    }

    It 'hides power-saving adapter tweaks on battery-powered PCs' {
        $script:SystemContext = $null
        $null = Get-SystemContext
        $script:SystemContext.HasBattery = $true
        @(Get-NetworkTweakRow | Where-Object Key -EQ '*SelectiveSuspend') | Should -BeNullOrEmpty
    }

    It 'computes the network fingerprint from the scan, without per-property queries' {
        $first = Get-NetworkFingerprint
        $first | Should -Match '^[A-F0-9]{12}$'
        Get-NetworkFingerprint | Should -Be $first
    }
}
