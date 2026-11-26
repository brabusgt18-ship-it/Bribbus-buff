# Shared fixtures for the cross-platform Pester suite.
# Dot-source this file inside BeforeAll: it loads BrabusDebloater.ps1 WITHOUT starting it and replaces
# every OS-specific provider (registry, power, network adapters, CIM, user SID) with in-memory fakes,
# so the backup engine, catalog builder and profiles run unchanged on Windows, Linux or macOS.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptUnderTest = Join-Path $script:RepoRoot 'BrabusDebloater.ps1'
. $script:ScriptUnderTest

$script:FakeRegistry = @{}
$script:FakePower = @{}
$script:FakeNetwork = @{}
$script:FakeUnwritable = @{}
$script:FakeSubKeys = @{}
$script:FakeAdmin = $false
$script:FakeScheme = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Get-CurrentUserSid { 'S-1-5-21-1000-TEST' }
function Test-IsAdministrator { $script:FakeAdmin }

function Get-SystemContext {
    if (-not $script:SystemContext) {
        $script:SystemContext = [pscustomobject]@{
            Build = 22631; Caption = 'Fake Windows 11'; LastBoot = (Get-Date).AddDays(-1)
            IsDomainJoined = $false; HasBattery = $false; IsDesktopOnAc = $true
        }
    }
    $script:SystemContext
}

function Get-UserRegistryValue {
    param([string]$Path, [string]$Key)
    $id = ('{0}|{1}' -f $Path, $Key).ToUpperInvariant()
    if ($script:FakeRegistry.ContainsKey($id)) {
        $entry = $script:FakeRegistry[$id]
        return New-ValueState -Exists $true -Kind $entry.Kind -Value $entry.Value
    }
    New-ValueState
}

function Set-UserRegistryValue {
    param([string]$Path, [string]$Key, $State)
    $id = ('{0}|{1}' -f $Path, $Key).ToUpperInvariant()
    if ($State.Exists) {
        $value = if ($State.Kind -eq 'DWord') { [int]$State.Value } else { [string]$State.Value }
        $script:FakeRegistry[$id] = @{ Kind = $State.Kind; Value = $value }
    } else {
        $script:FakeRegistry.Remove($id)
    }
}

function Set-FakeValue {
    param([string]$Path, [string]$Key, [string]$Kind = 'DWord', $Value)
    Set-UserRegistryValue -Path $Path -Key $Key -State (New-ValueState -Exists $true -Kind $Kind -Value $Value)
}

function Test-UserRegistryWritable {
    param([string]$Path)
    -not $script:FakeUnwritable.ContainsKey($Path)
}

function Get-UserRegistrySubKeyName {
    param([string]$Path)
    @($script:FakeSubKeys[$Path])
}

function Get-ActivePowerScheme { $script:FakeScheme }

function Read-PowerSetting {
    param([string]$Path, [string]$Key)
    $id = "$Path|$Key"
    if (-not $script:FakePower.ContainsKey($id)) { throw 'Impostazione AC non disponibile (2)' }
    New-ValueState -Exists $true -Kind 'DWord' -Value ([int]$script:FakePower[$id])
}

function Write-PowerSetting {
    param([string]$Path, [string]$Key, $State)
    $script:FakePower["$Path|$Key"] = [int]$State.Value
}

function Read-NetworkSetting {
    param([string]$Path, [string]$Key)
    New-ValueState -Exists $true -Kind 'String' -Value ([string]$script:FakeNetwork["$Path|$Key"])
}

function Write-NetworkSetting {
    param([string]$Path, [string]$Key, $State)
    $script:FakeNetwork["$Path|$Key"] = [string]$State.Value
}

function Test-BrowserInstalled { $false }
function Get-AdmxUserPolicy { }

function Reset-TestState {
    <# Fresh temporary state folder and empty fakes for each test. Returns the state root. #>
    $root = Join-Path ([IO.Path]::GetTempPath()) ('BrabusPester-' + [guid]::NewGuid().ToString('N'))
    Initialize-AppState -Root $root
    $script:FakeRegistry = @{}
    $script:FakePower = @{}
    $script:FakeNetwork = @{}
    $script:FakeUnwritable = @{}
    $script:FakeSubKeys = @{}
    $script:FakeAdmin = $false
    $script:SystemContext = $null
    $script:IsAdmin = $false
    Reset-SessionCache -All
    $root
}

function Remove-TestState {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) { Remove-Item -LiteralPath $Root -Recurse -Force }
}

function New-TestItem {
    <# A catalog-like row with a DWord (or given) target. #>
    param([string]$Name, [string]$Path = 'Software\BrabusPester', [string]$Key, $Value = 1, [string]$Kind = 'DWord', [string]$Category = 'Test')
    $before = Get-TweakValue -Path $Path -Key $Key
    New-TweakRow -Name $Name -Category $Category -Path $Path -Key $Key -Before $before -Target (New-ValueState -Exists $true -Kind $Kind -Value $Value) -Level 'Safe' -Note 'test'
}
