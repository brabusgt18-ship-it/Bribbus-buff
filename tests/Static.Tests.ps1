BeforeAll {
    $script:Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'BrabusDebloater.ps1'
    $script:Text = [IO.File]::ReadAllText($script:Path)
    $tokens = $null
    $script:ParseErrors = $null
    $script:Ast = [Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$script:ParseErrors)
    $script:Functions = @($script:Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
    # 'script:Name' test stubs count as 'Name'.
    $script:FunctionNames = @($script:Functions | ForEach-Object { $_.Name -replace '^script:', '' } | Sort-Object -Unique)

    function Get-FunctionAst([string]$Name) {
        $script:Functions | Where-Object Name -EQ $Name | Select-Object -First 1
    }

    $xamlFunction = Get-FunctionAst 'Get-MainWindowXaml'
    $hereString = $xamlFunction.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '<Window*' }, $true)
    $script:Xaml = [xml]$hereString.Value
    $script:XamlNames = @($script:Xaml.SelectNodes('//*[@Name]') | ForEach-Object { $_.GetAttribute('Name') })
}

Describe 'Source file hygiene' {
    It 'parses without errors' {
        $script:ParseErrors.Count | Should -Be 0
    }

    It 'is pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bytes = [IO.File]::ReadAllBytes($script:Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'uses CRLF line endings only (stable release checksums)' {
        ([regex]::Matches($script:Text, '(?<!\r)\n')).Count | Should -Be 0
    }

    It 'defines every function once (test stubs inside Invoke-UiTest excepted)' {
        $topLevel = @($script:Functions | Where-Object { -not $_.Parent.Parent.Parent -or $_.Parent.Parent.Parent -isnot [Management.Automation.Language.FunctionDefinitionAst] })
        @($topLevel | Group-Object Name | Where-Object Count -GT 1).Name | Should -BeNullOrEmpty
    }

    It 'uses approved verbs in every function name' {
        $approved = @(Get-Verb | ForEach-Object Verb)
        foreach ($name in $script:FunctionNames) {
            $name.Split('-')[0] | Should -BeIn $approved -Because $name
        }
    }

    It 'keeps the version in the script and in the window header aligned' {
        $version = [regex]::Match($script:Text, "AppVersion = '(\d+)\.(\d+)\.\d+'")
        $version.Success | Should -BeTrue
        $script:Text | Should -Match ([regex]::Escape("CONTROL CENTER  /  $($version.Groups[1].Value).$($version.Groups[2].Value) BETA"))
    }
}

Describe 'XAML layout and control references' {
    It 'has unique control names (the $script:Ui index is case-insensitive)' {
        @($script:XamlNames | Group-Object { $_.ToUpperInvariant() } | Where-Object Count -GT 1) | Should -BeNullOrEmpty
        $script:XamlNames.Count | Should -BeGreaterThan 90
    }

    It 'references only controls that exist in the XAML' {
        $patterns = @('\$script:Ui\.([A-Za-z]+)', "\`$script:Ui\['([A-Za-z]+)'\]", '\$ui\.([A-Za-z]+)', "Invoke-UiClick '([A-Za-z]+)'")
        $referenced = foreach ($pattern in $patterns) { [regex]::Matches($script:Text, $pattern) | ForEach-Object { $_.Groups[1].Value } }
        # (control, value) pairs drive the filter buttons and the speed test HUD.
        foreach ($name in 'Update-FilterButtonState', 'Show-NetworkTestState') {
            $referenced += [regex]::Matches((Get-FunctionAst $name).Extent.Text, "@\('([A-Za-z]+)', '[A-Za-z]+'\)") | ForEach-Object { $_.Groups[1].Value }
        }
        $register = Get-FunctionAst 'Register-MainWindowHandler'
        $loops = $register.FindAll({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] }, $true)
        $referenced += foreach ($loop in $loops) {
            $loop.Condition.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value
        }
        @($referenced | Where-Object { $_ -notin $script:XamlNames } | Sort-Object -Unique) | Should -BeNullOrEmpty
    }

    It 'wires every interactive button to a handler' {
        $buttons = @($script:Xaml.SelectNodes('//*[local-name()="Button"][@Name]') | ForEach-Object { $_.GetAttribute('Name') })
        $register = (Get-FunctionAst 'Register-MainWindowHandler').Extent.Text
        foreach ($button in $buttons) {
            $register | Should -Match "(\`$ui\.$button\.Add_Click|'$button')" -Because "$button needs a click handler"
        }
    }
}

Describe 'Command resolution' {
    BeforeAll {
        $module = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
        $profilePath = if ($module) { Join-Path (Join-Path $module.ModuleBase 'compatibility_profiles') 'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework.json' }
        $script:Known = $null
        if ($profilePath -and (Test-Path -LiteralPath $profilePath)) {
            # The profile has keys such as "psobject": read it as dictionaries, not PSCustomObjects.
            $json = [IO.File]::ReadAllText($profilePath)
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $windowsProfile = $json | ConvertFrom-Json -AsHashtable
            } else {
                Add-Type -AssemblyName System.Web.Extensions
                $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $serializer.MaxJsonLength = [int]::MaxValue
                $windowsProfile = $serializer.DeserializeObject($json)
            }
            $script:Known = @{}
            foreach ($moduleVersions in $windowsProfile['Runtime']['Modules'].Values) {
                foreach ($moduleData in $moduleVersions.Values) {
                    foreach ($kind in 'Cmdlets', 'Functions', 'Aliases') {
                        if ($moduleData.ContainsKey($kind) -and $moduleData[$kind]) { foreach ($name in $moduleData[$kind].Keys) { $script:Known[$name] = $kind } }
                    }
                }
            }
        }
    }

    It 'resolves every command to a script function or a Windows PowerShell 5.1 command' {
        if (-not $script:Known) { Set-ItResult -Skipped -Because 'PSScriptAnalyzer compatibility profiles not installed'; return }
        $commands = $script:Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique
        $unresolved = @($commands | Where-Object { $_ -notin $script:FunctionNames -and -not $script:Known.ContainsKey($_) })
        $unresolved | Should -BeNullOrEmpty
    }

    It 'keeps Measure-Connection self-contained (it runs in a separate runspace)' {
        $measure = Get-FunctionAst 'Measure-Connection'
        $calls = $measure.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }
        @($calls | Where-Object { $_ -in $script:FunctionNames }) | Should -BeNullOrEmpty
    }
}

Describe 'Static analysis' {
    It 'passes PSScriptAnalyzer with the repository settings' {
        if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Set-ItResult -Skipped -Because 'PSScriptAnalyzer not installed'; return }
        $settings = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSScriptAnalyzerSettings.psd1'
        $findings = @(Invoke-ScriptAnalyzer -Path $script:Path -Settings $settings)
        ($findings | ForEach-Object { "$($_.Line): $($_.RuleName) $($_.Message)" }) | Should -BeNullOrEmpty
    }
}
