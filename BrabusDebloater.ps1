<#
.SYNOPSIS
    BRABUS UTIL - Control Center 2.1: Windows tweak catalog with verified, mirrored backup and
    selective rollback.

.DESCRIPTION
    Local tool for Windows PowerShell 5.1 on Windows 10/11. It scans per-user preferences, local
    ADMX user policies, desktop AC power settings and physical network adapter properties, then
    applies only the rows you select. Before every write it stores a SHA-256 protected, mirrored
    write-ahead journal; after every write it reads the value back. Rollback is selective and never
    overwrites values changed by someone else. No resident process, no telemetry, nothing automatic.

.PARAMETER Scan
    Save a read-only JSON scan report in the state folder and exit.

.PARAMETER SelfTest
    Run the built-in backup/rollback test against an isolated HKCU test key and exit.

.PARAMETER Undo
    Restore every change recorded in the user/power journal and exit (network drivers: use the GUI).

.PARAMETER UiTest
    Run the automated GUI test on a hidden window with synthetic data and exit.

.PARAMETER ReleaseCheck
    Print a read-only JSON summary of catalog, audit and profile state and exit.

.PARAMETER ExportCurrentProfile
    Export a portable profile of the currently configured targets to a NEW file and exit.

.EXAMPLE
    powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\BrabusDebloater.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$SelfTest,
    [switch]$Undo,
    [switch]$UiTest,
    [switch]$ReleaseCheck,
    [string]$ExportCurrentProfile
)

$ErrorActionPreference = 'Stop'

#region Constants ---------------------------------------------------------------------------------

$script:AppVersion = '2.1.0'

# Row status values are also logic keys (filters, presets, profiles): never translate them in place.
$script:StatusAvailable = 'DISPONIBILE'
$script:StatusConfigured = 'GIA CONFIGURATO'

# Verification labels shown in the "Stato" column.
$script:Label = @{
    InvalidBackup  = 'BACKUP NON VALIDO'
    Original       = 'ORIGINALE / BACKUP'
    Drift          = 'NON VERIFICATO'
    TargetChanged  = 'TARGET CAMBIATO'
    RebootVerified = 'VERIFICATO DOPO RIAVVIO'
    RebootPending  = 'SALVATO / RIAVVIO PC'
    RestartApp     = 'SALVATO / RIAVVIA APP'
    PowerActive    = 'ATTIVO / VERIFICATO'
    Verified       = 'CONFIGURATO / VERIFICATO'
    ReadError      = 'ERRORE VERIFICA'
    NeedsAdmin     = 'RICHIEDE ADMIN'
}
# Labels that make a backed-up row unsafe to restore automatically.
$script:BlockingLabels = @($script:Label.Drift, $script:Label.TargetChanged, $script:Label.ReadError, $script:Label.InvalidBackup)

# Registry roots accepted inside backup records (HKCU-relative) plus the virtual providers.
$script:AllowedRecordPath = '^(Software\\|System\\|Control Panel\\|POWER\||NET\|)'

# Session caches: reset by Reset-SessionCache.
$script:SystemContext = $null
$script:AdmxCache = @{}
$script:WritableCache = @{}
$script:CurrentUserSid = $null
$script:LogWarning = ''
$script:BackupWarning = ''

#endregion

#region Utilities ---------------------------------------------------------------------------------

function Reset-SessionCache {
    <# Clears values cached per refresh. Hardware/OS context is kept unless -All is given. #>
    param([switch]$All)
    $script:WritableCache = @{}
    if ($All) {
        $script:SystemContext = $null
        $script:AdmxCache = @{}
    }
}

function Get-Sha256Hex {
    <# Upper-case hex SHA-256 of the UTF-8 bytes of a string (backup envelope format). #>
    param([AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-FullPath {
    <# Resolves a path against the PowerShell location (not the process directory used by .NET). #>
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-FileAtomic {
    <#
        Writes text through a unique temporary file, flushes it to disk and swaps it in place, so a
        crash never leaves a half-written file. UTF-8; BOM only when requested.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$Bom
    )
    $target = Get-FullPath $Path
    $temp = '{0}.{1}.tmp' -f $target, [guid]::NewGuid().ToString('N')
    $encoding = New-Object Text.UTF8Encoding($Bom.IsPresent)
    [byte[]]$preamble = $encoding.GetPreamble()
    [byte[]]$body = $encoding.GetBytes($Text)
    try {
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($preamble, 0, $preamble.Length)
            $stream.Write($body, 0, $body.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $target) {
            $previous = "$temp.previous"
            [IO.File]::Replace($temp, $target, $previous)
            Remove-Item -LiteralPath $previous -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temp, $target)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
    }
}

function Save-JsonFile {
    <# Atomic JSON report/profile writer (UTF-8 with BOM, readable by every older version). #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject,
        [int]$Depth = 8
    )
    Write-FileAtomic -Path $Path -Text (ConvertTo-Json -InputObject $InputObject -Depth $Depth) -Bom
}

function Read-JsonFile {
    <# Reads a JSON file with a size guard. BOM and non-BOM UTF-8 are both accepted. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaxBytes = 10MB
    )
    $full = Get-FullPath $Path
    if ((Get-Item -LiteralPath $full).Length -gt $MaxBytes) { throw "File troppo grande: $full" }
    [IO.File]::ReadAllText($full) | ConvertFrom-Json
}

function ConvertTo-UtcTime {
    <# Normalizes ISO-8601 strings (PS 5.1) and DateTime values (PS 7 ConvertFrom-Json) to UTC. #>
    param($Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function Invoke-NativeCommand {
    <#
        Runs an executable and returns its combined output. Exit codes are checked explicitly:
        with ErrorActionPreference=Stop, Windows PowerShell 5.1 would otherwise turn any stderr
        line into a terminating NativeCommandError.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure
    )
    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ }
    $code = $LASTEXITCODE
    $text = ($output -join [Environment]::NewLine)
    if ($code -ne 0 -and -not $AllowFailure) { throw "$FilePath ($code): $text" }
    [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentUserSid {
    if (-not $script:CurrentUserSid) {
        $script:CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $script:CurrentUserSid
}

#endregion

#region Application state -------------------------------------------------------------------------

function New-JournalContext {
    <#
        Describes one mirrored journal. Two journals share the backup folder: user/power values and
        network drivers. File names are unchanged since v2.0 so existing backups stay readable.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Primary,
        [Parameter(Mandatory)][string]$Mirror,
        [Parameter(Mandatory)][string]$Flag,
        [Parameter(Mandatory)][string]$Legacy
    )
    [pscustomobject]@{
        Name      = $Name
        Directory = $Directory
        Primary   = Join-Path $Directory $Primary
        Mirror    = Join-Path $Directory $Mirror
        Flag      = Join-Path $Directory $Flag
        Legacy    = $Legacy
        Warning   = ''
    }
}

function Initialize-AppState {
    <# Creates the state folder (default: %LOCALAPPDATA%\BrabusPC-Debloater-State) and journals. #>
    param([string]$Root)
    if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'BrabusPC-Debloater-State' }
    $backup = Join-Path $Root 'backup-v2'
    foreach ($dir in @($Root, $backup)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $foreign = @()
    if ($env:LOCALAPPDATA) {
        # State files of other optimizers that also manage power plans: never stack on top of them.
        $foreign = @(
            (Join-Path $env:LOCALAPPDATA 'BrabusPC-WinUtil-State\power.json'),
            (Join-Path $env:LOCALAPPDATA 'BrabusPCOptimizerState\restore.json')
        )
    }
    $script:Paths = [pscustomobject]@{
        Root              = $Root
        BackupDir         = $backup
        ChangeLog         = Join-Path $Root 'changes.jsonl'
        SpeedHistory      = Join-Path $Root 'speed-history.json'
        ForeignPowerState = $foreign
    }
    $script:UserJournal = New-JournalContext -Name 'User' -Directory $backup -Primary 'active.json' `
        -Mirror 'active-mirror.json' -Flag 'initialized.flag' -Legacy (Join-Path $Root 'undo.json')
    $script:NetworkJournal = New-JournalContext -Name 'Network' -Directory $backup -Primary 'network-active.json' `
        -Mirror 'network-mirror.json' -Flag 'network-initialized.flag' -Legacy (Join-Path $backup 'network-legacy.json')
}

function Get-JournalFor {
    <# Network driver rows live in their own journal; everything else in the user/power journal. #>
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('NET|')) { $script:NetworkJournal } else { $script:UserJournal }
}

function Write-ChangeLog {
    <# Appends one JSON line to changes.jsonl. Logging problems never block a change. #>
    param([string]$Action, $Before, $After, [string]$Status)
    $entry = [ordered]@{
        Time   = (Get-Date).ToString('o')
        Action = $Action
        Before = [string]$Before
        After  = [string]$After
        Status = $Status
    }
    try {
        $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:Paths.ChangeLog -Encoding UTF8 -ErrorAction Stop
    } catch {
        $script:LogWarning = "Log non disponibile: $($_.Exception.Message)"
    }
}

#endregion

#region Value model and providers -----------------------------------------------------------------
# A value state is {Exists; Kind; Value}. Paths select the provider:
#   'NET|<adapter guid>'                    -> network adapter advanced property (Key = keyword)
#   'POWER|<scheme guid>|<subgroup guid>'   -> AC power setting (Key = setting guid)
#   anything else                           -> HKCU registry key (Key = value name)

function New-ValueState {
    param([bool]$Exists = $false, [string]$Kind = '', $Value = $null)
    [pscustomobject]@{ Exists = $Exists; Kind = $Kind; Value = $Value }
}

function Test-SameState {
    param($Left, $Right)
    ($Left.Exists -eq $Right.Exists) -and
    ((-not $Left.Exists) -or ($Left.Kind -eq $Right.Kind -and [string]$Left.Value -ceq [string]$Right.Value))
}

function Format-State {
    param($State)
    if ($State.Exists) { [string]$State.Value } else { 'Non impostato' }
}

function Get-TweakValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key)
    if ($Path.StartsWith('NET|')) { return Read-NetworkSetting -Path $Path -Key $Key }
    if ($Path.StartsWith('POWER|')) { return Read-PowerSetting -Path $Path -Key $Key }
    Get-UserRegistryValue -Path $Path -Key $Key
}

function Set-TweakValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$State)
    if ($Path.StartsWith('NET|')) { Write-NetworkSetting -Path $Path -Key $Key -State $State; return }
    if ($Path.StartsWith('POWER|')) { Write-PowerSetting -Path $Path -Key $Key -State $State; return }
    Set-UserRegistryValue -Path $Path -Key $Key -State $State
}

function Get-UserRegistryValue {
    param([string]$Path, [string]$Key)
    $handle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
    try {
        if ($handle -and $handle.GetValueNames() -contains $Key) {
            $kind = [string]$handle.GetValueKind($Key)
            $value = $handle.GetValue($Key, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return New-ValueState -Exists $true -Kind $kind -Value $value
        }
        New-ValueState
    } finally {
        if ($handle) { $handle.Dispose() }
    }
}

function Set-UserRegistryValue {
    param([string]$Path, [string]$Key, $State)
    if ($State.Exists) {
        $value = switch ($State.Kind) {
            'DWord' { [int]$State.Value }
            'String' { [string]$State.Value }
            'ExpandString' { [string]$State.Value }
            default { throw "Tipo non supportato: $($State.Kind)" }
        }
        $handle = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Path)
        try {
            $handle.SetValue($Key, $value, [Microsoft.Win32.RegistryValueKind]$State.Kind)
        } finally {
            $handle.Dispose()
        }
    } else {
        $handle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path, $true)
        if ($handle) {
            try { $handle.DeleteValue($Key, $false) } finally { $handle.Dispose() }
        }
    }
}

function Test-UserRegistryWritable {
    <#
        True when the current token may write the value: the key itself needs SetValue, a missing key
        needs CreateSubKey on its nearest existing parent. Policy keys (HKCU\Software\Policies) are
        read-only for standard users, so rows there need an elevated session. Nothing is written.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($script:WritableCache.ContainsKey($Path)) { return $script:WritableCache[$Path] }
    $writable = $true
    $probe = $Path.TrimEnd('\')
    $exact = $true
    while ($probe) {
        $rights = if ($exact) { [Security.AccessControl.RegistryRights]::SetValue } else { [Security.AccessControl.RegistryRights]::CreateSubKey }
        try {
            $handle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probe, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
            if ($handle) { $handle.Dispose(); break }
        } catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            # Access denied means "not writable"; any other error keeps the row available (v2.0 behavior).
            if ($inner -is [Security.SecurityException] -or $inner -is [UnauthorizedAccessException]) { $writable = $false }
            break
        }
        $cut = $probe.LastIndexOf('\')
        $probe = if ($cut -gt 0) { $probe.Substring(0, $cut) } else { '' }
        $exact = $false
    }
    $script:WritableCache[$Path] = $writable
    $writable
}

function Test-TweakWritable {
    <# Only HKCU rows are probed; power and driver rows have their own checks at write time. #>
    param([Parameter(Mandatory)]$Row)
    if ($Row.Path.StartsWith('NET|') -or $Row.Path.StartsWith('POWER|')) { return $true }
    if ($script:IsAdmin) { return $true }
    try { Test-UserRegistryWritable -Path $Row.Path } catch { $true }
}

# --- Power (AC values of the active scheme, read natively: no locale-dependent parsing) ----------

function Initialize-NativeInterop {
    if (-not ('BrabusPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BrabusPower {
    [DllImport("powrprof.dll")]
    public static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
}
'@
    }
}

function Invoke-PowerCfg {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    (Invoke-NativeCommand -FilePath 'powercfg.exe' -ArgumentList $ArgumentList).Output
}

function Get-ActivePowerScheme {
    $match = [regex]::Match((Invoke-PowerCfg -ArgumentList '/getactivescheme'), '[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}')
    if (-not $match.Success) { throw 'Piano energetico non rilevato' }
    $match.Value
}

function Split-PowerPath {
    param([Parameter(Mandatory)][string]$Path)
    $parts = $Path.Split('|')
    if ($parts.Count -ne 3) { throw 'Indirizzo energia non valido' }
    [pscustomobject]@{ Scheme = [guid]$parts[1]; Subgroup = [guid]$parts[2] }
}

function Read-PowerSetting {
    param([string]$Path, [string]$Key)
    $address = Split-PowerPath $Path
    $scheme = $address.Scheme
    $subgroup = $address.Subgroup
    $setting = [guid]$Key
    [uint32]$value = 0
    $code = [BrabusPower]::PowerReadACValueIndex([IntPtr]::Zero, [ref]$scheme, [ref]$subgroup, [ref]$setting, [ref]$value)
    if ($code -ne 0) { throw "Impostazione AC non disponibile ($code)" }
    New-ValueState -Exists $true -Kind 'DWord' -Value ([int]$value)
}

function Write-PowerSetting {
    param([string]$Path, [string]$Key, $State)
    if (-not $State.Exists -or $State.Kind -ne 'DWord') { throw 'Valore energia non valido' }
    $address = Split-PowerPath $Path
    $scheme = $address.Scheme.ToString()
    $null = Invoke-PowerCfg -ArgumentList @('/setacvalueindex', $scheme, $address.Subgroup.ToString(), ([guid]$Key).ToString(), [string][int]$State.Value)
    # Re-activating the scheme makes Windows apply the new AC index immediately.
    if ((Get-ActivePowerScheme) -eq $scheme) { $null = Invoke-PowerCfg -ArgumentList @('/setactive', $scheme) }
}

# --- Network adapter advanced properties (physical adapters, whitelisted keywords only) ------------

function Get-NetworkDefinition {
    <# Keyword -> Name, target value, PWU, explanation. Only these keywords can ever be written. #>
    @{
        '*RSS'                   = @('Receive Side Scaling', '1', 'Medium', 'Distribuisce ricezione tra CPU; utile per throughput elevato.')
        '*RscIPv4'               = @('Receive Segment Coalescing IPv4', '1', 'Medium', 'Riduce overhead CPU; possibile compromesso latenza.')
        '*RscIPv6'               = @('Receive Segment Coalescing IPv6', '1', 'Medium', 'Riduce overhead CPU; possibile compromesso latenza.')
        '*LsoV2IPv4'             = @('Large Send Offload IPv4', '1', 'Medium', 'Offload trasmissione; misura throughput e latenza prima/dopo.')
        '*LsoV2IPv6'             = @('Large Send Offload IPv6', '1', 'Medium', 'Offload trasmissione; misura throughput e latenza prima/dopo.')
        '*InterruptModeration'   = @('Interrupt Moderation: off', '0', 'Medium', 'Possibile riduzione latenza, ma aumenta carico CPU; non sempre conviene.')
        '*EEE'                   = @('Energy Efficient Ethernet: off', '0', 'Low', 'Possibile riduzione ritardi di risveglio; aumenta consumo.')
        '*TCPChecksumOffloadIPv4' = @('TCP checksum IPv4', '3', 'Low', 'Offload checksum RX/TX; beneficio dipende dal driver.')
        '*TCPChecksumOffloadIPv6' = @('TCP checksum IPv6', '3', 'Low', 'Offload checksum RX/TX; beneficio dipende dal driver.')
        '*UDPChecksumOffloadIPv4' = @('UDP checksum IPv4', '3', 'Low', 'Offload checksum RX/TX; beneficio dipende dal driver.')
        '*UDPChecksumOffloadIPv6' = @('UDP checksum IPv6', '3', 'Low', 'Offload checksum RX/TX; beneficio dipende dal driver.')
        '*UsoIPv4'               = @('UDP Segmentation Offload IPv4', '1', 'Medium', 'Riduce overhead CPU per datagrammi grandi; dipende dal traffico.')
        '*UsoIPv6'               = @('UDP Segmentation Offload IPv6', '1', 'Medium', 'Riduce overhead CPU per datagrammi grandi; dipende dal traffico.')
        '*PacketCoalescing'      = @('Packet Coalescing: off', '0', 'Low', 'Possibile riduzione ritardo di aggregazione, maggiore carico CPU.')
        '*SelectiveSuspend'      = @('Selective Suspend: off', '0', 'Low', 'Solo desktop; evita sospensione selettiva della scheda, maggiori consumi.')
        '*IPChecksumOffloadIPv4' = @('IP checksum IPv4', '3', 'Low', 'Offload checksum RX/TX; beneficio dipende dal driver.')
    }
}

function Get-NetworkProperty {
    param([string]$Path, [string]$Key)
    $parts = $Path.Split('|')
    if ($parts.Count -ne 2 -or -not (Get-NetworkDefinition).ContainsKey($Key)) { throw 'Proprieta rete non autorizzata' }
    $guid = [guid]$parts[1]
    $adapter = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { [guid]$_.InterfaceGuid -eq $guid } | Select-Object -First 1
    if (-not $adapter) { throw 'Scheda fisica originale non rilevata' }
    $property = Get-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape($adapter.Name)) -RegistryKeyword $Key -ErrorAction Stop |
        Where-Object RegistryKeyword -EQ $Key | Select-Object -First 1
    if (-not $property -or @($property.RegistryValue).Count -ne 1) { throw 'Proprieta non disponibile o formato non supportato' }
    [pscustomobject]@{ Adapter = $adapter; Property = $property }
}

function Read-NetworkSetting {
    param([string]$Path, [string]$Key)
    $property = (Get-NetworkProperty -Path $Path -Key $Key).Property
    New-ValueState -Exists $true -Kind 'String' -Value ([string]$property.RegistryValue[0])
}

function Write-NetworkSetting {
    param([string]$Path, [string]$Key, $State)
    if (-not (Test-IsAdministrator)) { throw 'Richiede PowerShell come amministratore; non viene elevato automaticamente' }
    if (-not $State.Exists -or $State.Kind -ne 'String') { throw 'Stato rete non valido' }
    $found = Get-NetworkProperty -Path $Path -Key $Key
    if ([string]$State.Value -notin @($found.Property.ValidRegistryValues)) { throw 'Valore non supportato dal driver' }
    Set-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape($found.Adapter.Name)) -RegistryKeyword $Key `
        -RegistryValue @([string]$State.Value) -NoRestart -ErrorAction Stop
}

#endregion

#region Backup engine -----------------------------------------------------------------------------
# Envelope: {Format='BrabusBackupV2'; SHA256=<hash of Payload>; Payload=<JSON string>}
# Payload:  {Version=2; Owner=<user SID>; Time; Type='Journal'|'Snapshot'|'RestoreAttempt'; Records}
# Record:   {Name; Path; Key; Old; Target; BatchId; Id; Time}
# The journal is written to two files (primary + mirror) and verified BEFORE any value changes.

function Write-BackupEnvelope {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$Payload)
    $json = ConvertTo-Json -InputObject $Payload -Depth 16 -Compress
    $outer = ConvertTo-Json -InputObject @{ Format = 'BrabusBackupV2'; SHA256 = (Get-Sha256Hex $json); Payload = $json } -Compress
    Write-FileAtomic -Path $File -Text $outer
}

function Read-BackupEnvelope {
    param([Parameter(Mandatory)][string]$File)
    if (-not (Test-Path -LiteralPath $File)) { throw 'File backup assente' }
    if ((Get-Item -LiteralPath $File).Length -gt 50MB) { throw 'Backup troppo grande' }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $envelope = [IO.File]::ReadAllText($File, $strictUtf8) | ConvertFrom-Json
    if ($envelope.Format -ne 'BrabusBackupV2' -or $envelope.Payload -isnot [string] -or (Get-Sha256Hex $envelope.Payload) -cne $envelope.SHA256) {
        throw 'Checksum non valido'
    }
    $payload = $envelope.Payload | ConvertFrom-Json
    if ($payload.Version -ne 2 -or $payload.Owner -ne (Get-CurrentUserSid)) { throw 'Backup di un altro utente o versione' }
    $payload
}

function New-BackupPayload {
    param([object[]]$Records, [Parameter(Mandatory)][string]$Type)
    [ordered]@{
        Version = 2
        Owner   = Get-CurrentUserSid
        Time    = (Get-Date).ToString('o')
        Type    = $Type
        Records = @($Records)
    }
}

function New-BackupRecord {
    param($Item, $Old, [string]$BatchId)
    [pscustomobject]@{
        Name    = $Item.Name
        Path    = $Item.Path
        Key     = $Item.Key
        Old     = $Old
        Target  = $Item.TargetState
        BatchId = $BatchId
        Id      = [guid]::NewGuid().ToString('N')
        Time    = (Get-Date).ToString('o')
    }
}

function Assert-BackupRecord {
    <# Rejects anything a restore could misuse: unknown paths, kinds, keywords or duplicates. #>
    param([object[]]$Records)
    $seen = @{}
    foreach ($record in @($Records)) {
        if ($null -eq $record -or -not $record.Path -or -not $record.Key -or -not $record.Name -or -not $record.BatchId -or -not $record.Id) {
            throw 'Record backup incompleto'
        }
        if ($record.Path -notmatch $script:AllowedRecordPath -or $record.Path -match '[\r\n]') { throw 'Percorso backup non supportato' }
        foreach ($state in @($record.Old, $record.Target)) {
            if ($null -eq $state -or $state.Exists -isnot [bool]) { throw 'Stato backup non valido' }
            if ($state.Exists -and $state.Kind -notin @('DWord', 'String', 'ExpandString')) { throw 'Tipo backup non supportato' }
            if ($state.Exists -and $state.Kind -eq 'DWord') { $null = [int]$state.Value }
        }
        if ($record.Path.StartsWith('POWER|')) {
            $null = Split-PowerPath $record.Path
            $null = [guid]$record.Key
            if (-not $record.Old.Exists -or -not $record.Target.Exists -or $record.Old.Kind -ne 'DWord' -or $record.Target.Kind -ne 'DWord') {
                throw 'Stato energia non valido'
            }
        }
        if ($record.Path.StartsWith('NET|')) {
            $parts = $record.Path.Split('|')
            if ($parts.Count -ne 2 -or -not (Get-NetworkDefinition).ContainsKey($record.Key)) { throw 'Record rete non autorizzato' }
            $null = [guid]$parts[1]
            foreach ($state in @($record.Old, $record.Target)) {
                if (-not $state.Exists -or $state.Kind -ne 'String' -or [string]$state.Value -notmatch '^[0-9]{1,2}$') { throw 'Stato rete non valido' }
            }
        }
        $id = '{0}|{1}' -f $record.Path, $record.Key
        if ($seen.ContainsKey($id)) { throw 'Record duplicato nel backup' }
        $seen[$id] = $true
    }
}

function Read-JournalCopy {
    param([string]$File)
    try {
        $payload = Read-BackupEnvelope -File $File
        if ($payload.Type -ne 'Journal') { throw 'Tipo errato' }
        Assert-BackupRecord @($payload.Records)
        $payload
    } catch {
        $null
    }
}

function Read-Journal {
    <#
        Returns the active records. A damaged copy falls back to the other one (with a warning);
        two damaged copies, or a missing pair after initialization, block every change.
    #>
    param([Parameter(Mandatory)]$Journal)
    $Journal.Warning = ''
    $script:BackupWarning = ''
    $hasPrimary = Test-Path -LiteralPath $Journal.Primary
    $hasMirror = Test-Path -LiteralPath $Journal.Mirror
    if (-not $hasPrimary -and -not $hasMirror) {
        if (Test-Path -LiteralPath $Journal.Legacy) { throw 'Backup precedente non migrato: apri il centro backup' }
        if (Test-Path -LiteralPath $Journal.Flag) { throw 'Entrambe le copie backup mancanti: nessuna modifica consentita' }
        return
    }
    $primary = Read-JournalCopy $Journal.Primary
    $mirror = Read-JournalCopy $Journal.Mirror
    if (-not $primary -and -not $mirror) { throw 'Entrambe le copie del backup non valide: nessuna scrittura consentita' }
    if (-not $primary) {
        $Journal.Warning = 'Copia primaria danneggiata o assente: uso copia ridondante'
        $primary = $mirror
    } elseif (-not $mirror) {
        $Journal.Warning = 'Copia ridondante danneggiata o assente'
    } elseif ((ConvertTo-Json -InputObject $primary -Depth 16 -Compress) -cne (ConvertTo-Json -InputObject $mirror -Depth 16 -Compress)) {
        $Journal.Warning = 'Copie divergenti: primaria prioritaria (scritta per prima)'
    }
    $script:BackupWarning = $Journal.Warning
    foreach ($record in @($primary.Records)) {
        if ($null -ne $record) { Write-Output $record }
    }
}

function Save-Journal {
    <# Writes primary then mirror, reads both back and refuses to continue unless identical. #>
    param([Parameter(Mandatory)]$Journal, [object[]]$Records = @())
    Assert-BackupRecord @($Records)
    $payload = New-BackupPayload -Records @($Records) -Type 'Journal'
    Write-BackupEnvelope -File $Journal.Primary -Payload $payload
    Write-BackupEnvelope -File $Journal.Mirror -Payload $payload
    $primary = ConvertTo-Json -InputObject (Read-BackupEnvelope -File $Journal.Primary) -Depth 16 -Compress
    $mirror = ConvertTo-Json -InputObject (Read-BackupEnvelope -File $Journal.Mirror) -Depth 16 -Compress
    if ($primary -cne $mirror) { throw 'Copie backup non identiche; modifica bloccata' }
    if (-not (Test-Path -LiteralPath $Journal.Flag)) { [IO.File]::WriteAllText($Journal.Flag, '2') }
}

function Find-JournalRecord {
    param([object[]]$Records, [string]$Path, [string]$Key)
    @($Records | Where-Object { $_.Path -eq $Path -and $_.Key -eq $Key }) | Select-Object -First 1
}

function Invoke-LegacyMigration {
    <# Converts the v1.x undo.json (single copy) into the mirrored v2 journal, keeping archives. #>
    param([Parameter(Mandatory)]$Journal)
    if (-not (Test-Path -LiteralPath $Journal.Legacy)) { return }
    if ((Test-Path -LiteralPath $Journal.Primary) -or (Test-Path -LiteralPath $Journal.Mirror)) {
        throw 'Backup legacy e v2 entrambi presenti: controllo manuale richiesto'
    }
    $batch = [guid]::NewGuid().ToString('N')
    # No @() around ConvertFrom-Json: PS 5.1 emits a JSON array as ONE object, foreach unrolls it.
    $legacyRecords = Get-Content -LiteralPath $Journal.Legacy -Raw | ConvertFrom-Json
    $records = @(foreach ($legacy in $legacyRecords) {
            [pscustomobject]@{
                Name = $legacy.Name; Path = $legacy.Path; Key = $legacy.Key; Old = $legacy.Old; Target = $legacy.Target
                BatchId = $batch; Id = [guid]::NewGuid().ToString('N'); Time = (Get-Date).ToString('o')
            }
        })
    Assert-BackupRecord $records
    $archive = Join-Path $Journal.Directory ('legacy-' + $batch + '.json')
    Copy-Item -LiteralPath $Journal.Legacy -Destination $archive
    if ((Get-FileHash -LiteralPath $archive).Hash -ne (Get-FileHash -LiteralPath $Journal.Legacy).Hash) { throw 'Copia legacy non verificata' }
    Save-Journal -Journal $Journal -Records $records
    Move-Item -LiteralPath $Journal.Legacy -Destination (Join-Path $Journal.Directory ('legacy-original-' + $batch + '.json'))
}

function Assert-PowerItemSafe {
    param([Parameter(Mandatory)]$Item)
    if ((Get-ActivePowerScheme) -ne $Item.Path.Split('|')[1]) { throw 'Piano energetico cambiato: esegui una nuova scansione' }
    foreach ($file in @($script:Paths.ForeignPowerState)) {
        if (Test-Path -LiteralPath $file) { throw 'Ripristina prima altri optimizer' }
    }
}

function New-BackupSnapshot {
    <#
        Captures the original value of every item that will change, as one batch, into an immutable
        snapshot file (verified by reading it back). Nothing is applied here.
    #>
    param([Parameter(Mandatory)]$Journal, [object[]]$Items)
    $existing = @(Read-Journal -Journal $Journal)
    $batch = [guid]::NewGuid().ToString('N')
    $records = @(foreach ($item in @($Items)) {
            $old = Get-TweakValue -Path $item.Path -Key $item.Key
            if (Test-SameState $old $item.TargetState) { continue }
            if (Find-JournalRecord -Records $existing -Path $item.Path -Key $item.Key) {
                throw "Backup gia attivo: $($item.Name). Ripristina prima di riapplicare."
            }
            if ($item.Path.StartsWith('POWER|') -and (Get-ActivePowerScheme) -ne $item.Path.Split('|')[1]) {
                throw 'Piano energetico cambiato: esegui una nuova scansione'
            }
            New-BackupRecord -Item $item -Old $old -BatchId $batch
        })
    Assert-BackupRecord $records
    if ($records.Count) {
        $file = Join-Path $Journal.Directory ('snapshot-' + $batch + '.json')
        Write-BackupEnvelope -File $file -Payload (New-BackupPayload -Records $records -Type 'Snapshot')
        $readBack = @((Read-BackupEnvelope -File $file).Records)
        Assert-BackupRecord $readBack
        if ($readBack.Count -ne $records.Count) { throw 'Snapshot incompleto' }
    }
    [pscustomobject]@{ Id = $batch; Records = $records }
}

function Set-Tweak {
    <#
        Applies one catalog row: write-ahead journal (both copies verified), re-check the live value,
        write, read back. A batch from New-BackupSnapshot may be supplied; otherwise one is created.
    #>
    param([Parameter(Mandatory)]$Item, $Batch)
    $journal = Get-JournalFor -Path $Item.Path
    if ($Item.Path.StartsWith('POWER|')) { Assert-PowerItemSafe -Item $Item }
    $old = Get-TweakValue -Path $Item.Path -Key $Item.Key
    $target = $Item.TargetState
    if (Test-SameState $old $target) {
        Write-ChangeLog -Action $Item.Name -Before (Format-State $old) -After (Format-State $target) -Status $script:StatusConfigured
        return
    }
    if (-not $Batch) { $Batch = New-BackupSnapshot -Journal $journal -Items @($Item) }
    $record = Find-JournalRecord -Records $Batch.Records -Path $Item.Path -Key $Item.Key
    if (-not $record -or -not (Test-SameState $old $record.Old) -or -not (Test-SameState $target $record.Target)) {
        throw 'Valore cambiato dopo snapshot; ripetere scansione'
    }
    $entries = @(Read-Journal -Journal $journal)
    if (Find-JournalRecord -Records $entries -Path $Item.Path -Key $Item.Key) { throw 'Backup gia presente' }
    Save-Journal -Journal $journal -Records (@($entries) + $record)
    try {
        if (-not (Test-SameState (Get-TweakValue -Path $Item.Path -Key $Item.Key) $record.Old)) { throw 'Valore cambiato prima della scrittura' }
        Set-TweakValue -Path $Item.Path -Key $Item.Key -State $target
        $actual = Get-TweakValue -Path $Item.Path -Key $Item.Key
        if (-not (Test-SameState $actual $target)) { throw 'Verifica fallita' }
        Write-ChangeLog -Action $Item.Name -Before (Format-State $old) -After (Format-State $actual) -Status 'VERIFICATO'
    } catch {
        Write-ChangeLog -Action $Item.Name -Before (Format-State $old) -After '?' -Status ('ERRORE: ' + $_.Exception.Message)
        throw
    }
}

function Restore-JournalRecord {
    <#
        Restores records newest-first. A value changed by someone else (neither original nor target)
        is never overwritten and its record is kept. Returns one result per record.
    #>
    param([Parameter(Mandatory)]$Journal, [string[]]$Id)
    $selected = @(Read-Journal -Journal $Journal | Where-Object { $_.Id -in $Id })
    if (-not $selected.Count) { return }
    $attempt = Join-Path $Journal.Directory ('restore-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-BackupEnvelope -File $attempt -Payload (New-BackupPayload -Records $selected -Type 'RestoreAttempt')
    $null = Read-BackupEnvelope -File $attempt
    [array]::Reverse($selected)
    foreach ($record in $selected) {
        try {
            $now = Get-TweakValue -Path $record.Path -Key $record.Key
            if (-not (Test-SameState $now $record.Old)) {
                if (-not (Test-SameState $now $record.Target)) { throw 'Valore cambiato esternamente: non sovrascritto' }
                Set-TweakValue -Path $record.Path -Key $record.Key -State $record.Old
                if (-not (Test-SameState (Get-TweakValue -Path $record.Path -Key $record.Key) $record.Old)) { throw 'Ripristino non verificato' }
            }
            Save-Journal -Journal $Journal -Records @(Read-Journal -Journal $Journal | Where-Object Id -NE $record.Id)
            Write-ChangeLog -Action $record.Name -Before (Format-State $now) -After (Format-State $record.Old) -Status 'RIPRISTINATO'
            [pscustomobject]@{ Record = $record; OK = $true; Error = '' }
        } catch {
            Write-ChangeLog -Action $record.Name -Before '-' -After '-' -Status ('ERRORE RIPRISTINO: ' + $_.Exception.Message)
            [pscustomobject]@{ Record = $record; OK = $false; Error = $_.Exception.Message }
        }
    }
}

function Restore-JournalRecordStrict {
    <# Same as Restore-JournalRecord but throws when any record could not be restored. #>
    param([Parameter(Mandatory)]$Journal, [string[]]$Id)
    $failed = @(Restore-JournalRecord -Journal $Journal -Id $Id | Where-Object { -not $_.OK }).Count
    if ($failed) { throw "$failed modifiche non ripristinate; backup conservato" }
}

function Restore-AllUserTweak {
    Restore-JournalRecordStrict -Journal $script:UserJournal -Id @(Read-Journal -Journal $script:UserJournal | ForEach-Object Id)
}

function Get-BackupStatus {
    $records = @(Read-Journal -Journal $script:UserJournal)
    [pscustomobject]@{
        Pending   = $records.Count
        Snapshots = @(Get-ChildItem -LiteralPath $script:Paths.BackupDir -Filter 'snapshot-*.json' -File).Count
        Warning   = $script:UserJournal.Warning
    }
}

function Invoke-ApplyBatch {
    <#
        Applies rows one by one (a failure never stops the others). Rows of the same journal share
        one snapshot/BatchId; if the shared snapshot cannot be taken, each row falls back to its own.
    #>
    param([object[]]$Items)
    $Items = @($Items | Where-Object { $_ })
    $ok = 0
    $errors = @()
    $batches = @{}
    foreach ($group in @($Items | Group-Object { (Get-JournalFor -Path $_.Path).Name })) {
        try {
            $batches[$group.Name] = New-BackupSnapshot -Journal (Get-JournalFor -Path $group.Group[0].Path) -Items $group.Group
        } catch {
            $batches[$group.Name] = $null
        }
    }
    foreach ($item in @($Items)) {
        try {
            Set-Tweak -Item $item -Batch $batches[(Get-JournalFor -Path $item.Path).Name]
            if (-not (Test-SameState (Get-TweakValue -Path $item.Path -Key $item.Key) $item.TargetState)) { throw 'Rilettura finale non corrisponde' }
            $ok++
        } catch {
            $errors += "$($item.Name): $($_.Exception.Message)"
            Write-ChangeLog -Action $item.Name -Before '-' -After '-' -Status ('ERRORE: ' + $_.Exception.Message)
        }
    }
    [pscustomobject]@{ OK = $ok; Failed = $errors.Count; Errors = $errors }
}

function Invoke-RestoreBatch {
    <# Restores the backup record of each row (rows or journal records), one call per journal. #>
    param([object[]]$Items)
    $Items = @($Items | Where-Object { $_ })
    $ok = 0
    $errors = @()
    foreach ($group in @($Items | Group-Object { (Get-JournalFor -Path $_.Path).Name })) {
        $journal = Get-JournalFor -Path $group.Group[0].Path
        $records = @()
        try {
            $records = @(Read-Journal -Journal $journal)
        } catch {
            foreach ($item in $group.Group) { $errors += "$($item.Name): $($_.Exception.Message)" }
            continue
        }
        $wanted = @{}
        foreach ($item in $group.Group) {
            $record = Find-JournalRecord -Records $records -Path $item.Path -Key $item.Key
            if ($record) { $wanted[$record.Id] = $item } else { $errors += "$($item.Name): Backup originale assente" }
        }
        if (-not $wanted.Count) { continue }
        foreach ($result in @(Restore-JournalRecord -Journal $journal -Id @($wanted.Keys))) {
            $item = $wanted[$result.Record.Id]
            if (-not $result.OK) { $errors += "$($item.Name): $($result.Error)"; continue }
            try {
                if (-not (Test-SameState (Get-TweakValue -Path $item.Path -Key $item.Key) $result.Record.Old)) { throw 'Rilettura finale ripristino non corrisponde' }
                $ok++
            } catch {
                $errors += "$($item.Name): $($_.Exception.Message)"
            }
        }
    }
    [pscustomobject]@{ OK = $ok; Failed = $errors.Count; Errors = $errors }
}

#endregion

#region System context (cached per session) ------------------------------------------------------

function Get-SystemContext {
    <# One CIM round-trip per session instead of one per catalog section (v2.0: ~9 per refresh). #>
    if ($script:SystemContext) { return $script:SystemContext }
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $hasBattery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    $script:SystemContext = [pscustomobject]@{
        Build          = [int]$os.BuildNumber
        Caption        = [string]$os.Caption
        LastBoot       = $os.LastBootUpTime
        IsDomainJoined = [bool]$computer.PartOfDomain
        HasBattery     = $hasBattery
        # Power tweaks are offered only on desktops without battery, AC values only.
        IsDesktopOnAc  = ($computer.PCSystemType -eq 1 -and -not $hasBattery)
    }
    $script:SystemContext
}

function Import-AdmxDocument {
    <# Parses each ADMX template once per session (v2.0 re-parsed Taskbar.admx six times per scan). #>
    param([Parameter(Mandatory)][string]$File)
    if ($script:AdmxCache.ContainsKey($File)) { return }
    $document = $null
    $path = Join-Path (Join-Path $env:windir 'PolicyDefinitions') $File
    if (Test-Path -LiteralPath $path) {
        try { $document = [xml](Get-Content -LiteralPath $path -Raw) } catch { $document = $null }
    }
    $script:AdmxCache[$File] = $document
}

function Get-AdmxUserPolicy {
    <# Reads key/value/enabled value of a user policy from the local Microsoft ADMX template. #>
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Name, [string[]]$Class = @('User'))
    Import-AdmxDocument -File $File
    $document = $script:AdmxCache[$File]
    if (-not $document) { return }
    $policy = $document.policyDefinitions.policies.policy | Where-Object {
        $_.name -eq $Name -and $_.class -in $Class -and $_.key -and $_.valueName -and $null -ne $_.enabledValue.decimal.value
    } | Select-Object -First 1
    if ($policy) {
        [pscustomobject]@{ Key = [string]$policy.key; ValueName = [string]$policy.valueName; Value = [int]$policy.enabledValue.decimal.value }
    }
}

function Get-UserRegistrySubKeyName {
    param([Parameter(Mandatory)][string]$Path)
    $handle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
    if (-not $handle) { return }
    try { $handle.GetSubKeyNames() } finally { $handle.Dispose() }
}

function Test-BrowserInstalled {
    param([Parameter(Mandatory)][string]$Executable, [string[]]$Directory)
    foreach ($dir in $Directory) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir $Executable))) { return $true }
    }
    foreach ($hive in @('HKLM:', 'HKCU:')) {
        if (Test-Path -LiteralPath "$hive\Software\Microsoft\Windows\CurrentVersion\App Paths\$Executable") { return $true }
    }
    $false
}

#endregion

#region Catalog definitions -----------------------------------------------------------------------
# Static registry tweaks. Fields:
#   Name, Category, Path (HKCU-relative), Key, Value, Note
#   Level        'Safe' | 'Gaming' | 'OptIn' (default). SAFE preset = Safe; GAMING/ULTIMATE = Safe+Gaming.
#   Kind         'DWord' (default) | 'String'
#   MinBuild     only on Windows builds >= value (22000 = Windows 11)
#   ExistingOnly only when Windows already created the value (avoids inventing undocumented keys)
#   AllowedBefore only when the current value is one of these
#   PersonalOnly skipped on domain-joined PCs
# A value that exists with a different registry type is never touched.

function Get-StaticTweakDefinition {
    $adv = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $explorer = 'Software\Microsoft\Windows\CurrentVersion\Explorer'
    $personalize = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $searchSettings = 'Software\Microsoft\Windows\CurrentVersion\SearchSettings'
    $notifications = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    $gameBar = 'Software\Microsoft\GameBar'
    $desktop = 'Control Panel\Desktop'
    $metrics = 'Control Panel\Desktop\WindowMetrics'
    $mouse = 'Control Panel\Mouse'
    $keyboard = 'Control Panel\Keyboard'
    $tabletTip = 'Software\Microsoft\TabletTip\1.7'
    $inputSettings = 'Software\Microsoft\Input\Settings'
    $clipboard = 'Software\Microsoft\Windows\CurrentVersion\Clipboard'
    $build = '; effetto dipende dalla build'
    $taskbarNote = 'Preferenza utente, non FPS; build dipendente'
    $stringNote = 'Preferenza Windows; puo richiedere nuovo accesso; non modifica latenza gioco'

    @(
        # --- Gaming and capture ---------------------------------------------------------------------
        @{ Name = 'Windows Game Mode'; Category = 'Gaming'; Level = 'Gaming'; Path = $gameBar; Key = 'AutoGameModeEnabled'; Value = 1; Note = 'Attiva Game Mode; beneficio dipende dal gioco' }
        @{ Name = 'Registrazione game in background'; Category = 'Gaming'; Path = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; Key = 'AppCaptureEnabled'; Value = 0; Note = 'Disabilita cattura Windows; non modifica Medal' }
        @{ Name = 'Cattura gioco Game DVR'; Category = 'Gaming'; Path = 'System\GameConfigStore'; Key = 'GameDVR_Enabled'; Value = 0; Note = 'Disabilita cattura Windows; scegliere solo se non usata' }

        # --- Suggestions and promoted content -------------------------------------------------------
        @{ Name = 'Suggerimenti e app promosse'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'SilentInstalledAppsEnabled'; Value = 0; Note = 'Preferenza utente; il supporto varia per build' }
        @{ Name = 'Contenuti suggeriti'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'ContentDeliveryAllowed'; Value = 0; Note = 'Preferenza utente per contenuti promossi; verifica dopo aggiornamenti' }
        @{ Name = 'Suggerimenti in Impostazioni'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'SubscribedContent338393Enabled'; Value = 0; Note = 'Preferenza utente; effetto dipende dalla versione' }
        @{ Name = 'Suggerimenti Windows'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'SubscribedContent338389Enabled'; Value = 0; Note = 'Preferenza utente; effetto dipende dalla versione' }
        @{ Name = 'Pubblicita in Esplora file'; Category = 'Debloat'; Level = 'Safe'; Path = $adv; Key = 'ShowSyncProviderNotifications'; Value = 0; Note = 'Riduce notifiche promozionali del provider di sincronizzazione' }
        @{ Name = 'Esperienze personalizzate'; Category = 'Privacy'; Level = 'Safe'; Path = 'Software\Microsoft\Windows\CurrentVersion\Privacy'; Key = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0; Note = 'Non disattiva la diagnostica obbligatoria' }
        @{ Name = 'Pulsante Widget nella barra'; Category = 'Debloat'; MinBuild = 22000; Path = $adv; Key = 'TaskbarDa'; Value = 0; Note = 'Nasconde il pulsante; non rimuove componenti' }
        @{ Name = 'Privacy ID pubblicitario'; Category = 'Privacy'; Level = 'Safe'; Path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Key = 'Enabled'; Value = 0; Note = 'Disabilita ID pubblicitario utente' }
        @{ Name = 'Suggerimenti schermata di benvenuto'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'SubscribedContent310093Enabled'; Value = 0; Note = 'Preferenza per esperienze di benvenuto' }
        @{ Name = 'Suggerimenti in Timeline'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'SubscribedContent338388Enabled'; Value = 0; Note = 'Preferenza contenuti suggeriti' }
        @{ Name = 'Suggerimenti in Start'; Category = 'Debloat'; Level = 'Safe'; Path = $cdm; Key = 'SystemPaneSuggestionsEnabled'; Value = 0; Note = 'Preferenza; dipende dalla build' }
        @{ Name = 'Suggerimenti post configurazione'; Category = 'Debloat'; Level = 'Safe'; Path = 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Key = 'ScoobeSystemSettingEnabled'; Value = 0; Note = 'Riduce inviti a completare la configurazione' }
        @{ Name = 'Notifiche suggerimenti'; Category = 'Debloat'; Level = 'Safe'; Path = "$notifications\Windows.SystemToast.Suggested"; Key = 'Enabled'; Value = 0; Note = 'Solo notifiche di suggerimenti' }
        @{ Name = 'Feedback richiesto'; Category = 'Privacy'; Path = 'Software\Microsoft\Siuf\Rules'; Key = 'NumberOfSIUFInPeriod'; Value = 0; Note = 'Preferenza frequenza feedback; non blocca telemetria obbligatoria' }
        @{ Name = 'Risultati web nella ricerca Start'; Category = 'Privacy'; Path = 'Software\Policies\Microsoft\Windows\Explorer'; Key = 'DisableSearchBoxSuggestions'; Value = 1; Note = 'Preferenza ricerca; policy e supporto dipendono dalla build' }
        @{ Name = 'Evidenziazioni ricerca'; Category = 'Debloat'; Level = 'Safe'; Path = $searchSettings; Key = 'IsDynamicSearchBoxEnabled'; Value = 0; Note = 'Riduce contenuti dinamici della ricerca' }
        @{ Name = 'Disattiva suggerimenti soft landing'; Category = 'Debloat'; Path = $cdm; Key = 'SoftLandingEnabled'; Value = 0; Note = 'Preferenza legacy: effetto variabile' }
        @{ Name = 'Disattiva sottoscrizioni promozionali'; Category = 'Debloat'; Path = $cdm; Key = 'SubscribedContentEnabled'; Value = 0; Note = 'Preferenza utente per contenuti promozionali' }
        @{ Name = 'Rotazione contenuti schermata di blocco'; Category = 'Debloat'; Path = $cdm; Key = 'RotatingLockScreenEnabled'; Value = 0; Note = 'Preferenza contenuti lock screen' }
        @{ Name = 'Overlay contenuti schermata di blocco'; Category = 'Debloat'; Path = $cdm; Key = 'RotatingLockScreenOverlayEnabled'; Value = 0; Note = 'Preferenza suggerimenti lock screen' }
        @{ Name = 'Mostra consigli account in Start'; Category = 'Debloat'; Path = $adv; Key = 'Start_AccountNotifications'; Value = 0; Note = 'Preferenza dipendente dalla build' }

        # --- Visual and shell -----------------------------------------------------------------------
        @{ Name = 'Trasparenza interfaccia'; Category = 'Visual'; Level = 'Gaming'; Path = $personalize; Key = 'EnableTransparency'; Value = 0; Note = 'Riduce effetti visivi; nessuna promessa FPS' }
        @{ Name = 'Animazioni barra applicazioni'; Category = 'Visual'; Level = 'Gaming'; Path = $adv; Key = 'TaskbarAnimations'; Value = 0; Note = 'Riduce animazioni shell' }
        @{ Name = 'Icona Task View'; Category = 'Visual'; Path = $adv; Key = 'ShowTaskViewButton'; Value = 0; Note = 'Nasconde solo il pulsante; Win+Tab resta disponibile' }
        @{ Name = 'Tema app scuro'; Category = 'Visual'; Path = $personalize; Key = 'AppsUseLightTheme'; Value = 0; Note = 'Preferenza tema Windows, non impone tema a tutte le app' }
        @{ Name = 'Tema sistema scuro'; Category = 'Visual'; Path = $personalize; Key = 'SystemUsesLightTheme'; Value = 0; Note = 'Preferenza tema Windows' }
        @{ Name = 'Barra applicazioni: ricerca nascosta'; Category = 'Visual'; MinBuild = 22000; Path = 'Software\Microsoft\Windows\CurrentVersion\Search'; Key = 'SearchboxTaskbarMode'; Value = 0; Note = 'Ricerca da Start resta disponibile' }
        @{ Name = 'Allineamento barra a sinistra'; Category = 'Visual'; MinBuild = 22000; Path = $adv; Key = 'TaskbarAl'; Value = 0; Note = 'Solo preferenza estetica' }
        @{ Name = 'Mostra desktop con angolo barra'; Category = 'Visual'; Path = $adv; Key = 'TaskbarSd'; Value = 1; Note = 'Preferenza usabilita; Windows 11 compatibile' }
        @{ Name = 'Disattiva Aero Shake'; Category = 'Visual'; Path = $adv; Key = 'DisallowShaking'; Value = 1; Note = 'Evita minimizzazione finestre tramite gesto' }
        @{ Name = 'Animazioni finestre'; Category = 'Visual'; Kind = 'String'; Path = $metrics; Key = 'MinAnimate'; Value = '0'; Note = 'Disabilita animazioni min/max; nuovo accesso puo essere necessario' }
        @{ Name = 'Ritardo apertura menu 150 ms'; Category = 'Visual'; Kind = 'String'; Path = $desktop; Key = 'MenuShowDelay'; Value = '150'; Note = 'Preferenza UX, non cambia latenza input in gioco' }

        # --- Explorer -------------------------------------------------------------------------------
        @{ Name = 'Estensioni file visibili'; Category = 'Explorer'; Level = 'Safe'; Path = $adv; Key = 'HideFileExt'; Value = 0; Note = 'Mostra estensioni dei file; sicurezza e usabilita' }
        @{ Name = 'File nascosti visibili'; Category = 'Explorer'; Path = $adv; Key = 'Hidden'; Value = 1; Note = 'Mostra file nascosti; non mostra file protetti di sistema' }
        @{ Name = 'Apertura Esplora file: Questo PC'; Category = 'Explorer'; Path = $adv; Key = 'LaunchTo'; Value = 1; Note = 'Preferenza navigazione' }
        @{ Name = 'Checkbox selezione file'; Category = 'Explorer'; Path = $adv; Key = 'AutoCheckSelect'; Value = 1; Note = 'Preferenza selezione file' }
        @{ Name = 'Mostra percorso completo in titolo'; Category = 'Explorer'; Path = "$explorer\CabinetState"; Key = 'FullPath'; Value = 1; Note = 'Preferenza Esplora file; supporto build variabile' }
        @{ Name = 'Miniature al posto delle icone: off'; Category = 'Explorer'; Path = $adv; Key = 'IconsOnly'; Value = 1; Note = 'Riduce generazione miniature; perde anteprime' }
        @{ Name = 'Mostra tipo elemento nei suggerimenti'; Category = 'Explorer'; Path = $adv; Key = 'ShowInfoTip'; Value = 0; Note = 'Nasconde descrizioni al passaggio del mouse' }
        @{ Name = 'Apri cartelle in processo separato'; Category = 'Explorer'; Path = $adv; Key = 'SeparateProcess'; Value = 1; Note = 'Isolamento Explorer; puo usare piu RAM, non ottimizzazione FPS' }
        @{ Name = 'Mostra barra di stato Explorer'; Category = 'Explorer'; Path = $adv; Key = 'ShowStatusBar'; Value = 1; Note = 'Preferenza visiva' }
        @{ Name = 'Mostra unita senza supporti'; Category = 'Explorer'; Path = $adv; Key = 'HideDrivesWithNoMedia'; Value = 0; Note = 'Mostra unita senza supporti' }

        # --- Privacy --------------------------------------------------------------------------------
        @{ Name = 'File recenti in Home'; Category = 'Privacy'; Path = $explorer; Key = 'ShowRecent'; Value = 0; Note = 'Non mostra file recenti in Home' }
        @{ Name = 'Cartelle frequenti in Home'; Category = 'Privacy'; Path = $explorer; Key = 'ShowFrequent'; Value = 0; Note = 'Non mostra cartelle frequenti in Home' }
        @{ Name = 'Cronologia app avviate'; Category = 'Privacy'; Path = $adv; Key = 'Start_TrackProgs'; Value = 0; Note = 'Influisce sui suggerimenti basati sulle app' }
        @{ Name = 'Preferenza lingua non condivisa sul web'; Category = 'Privacy'; Path = 'Control Panel\International\User Profile'; Key = 'HttpAcceptLanguageOptOut'; Value = 1; Note = 'Influenza lingua automatica dei siti compatibili' }
        @{ Name = 'Diagnostica digitazione facoltativa'; Category = 'Privacy'; Path = 'Software\Microsoft\Input\TIPC'; Key = 'Enabled'; Value = 0; Note = 'Riduce invio facoltativo dati digitazione; non tocca riconoscimento vocale' }
        @{ Name = 'Colori file compressi/cifrati: off'; Category = 'Privacy'; Path = $adv; Key = 'ShowCompColor'; Value = 0; Note = 'Non colora file NTFS compressi o cifrati' }
        @{ Name = 'Ricerca: cronologia dispositivo'; Category = 'Privacy'; Path = $searchSettings; Key = 'IsDeviceSearchHistoryEnabled'; Value = 0; Note = 'Disattiva salvataggio cronologia ricerca locale; non cancella dati' }
        @{ Name = 'Ricerca: contenuti cloud account personale'; Category = 'Privacy'; Path = $searchSettings; Key = 'IsMSACloudSearchEnabled'; Value = 0; Note = 'Non mostra contenuti cloud nella ricerca' }
        @{ Name = 'Ricerca: contenuti cloud lavoro/scuola'; Category = 'Privacy'; Path = $searchSettings; Key = 'IsAADCloudSearchEnabled'; Value = 0; Note = 'Non mostra contenuti cloud lavoro/scuola; non usare su PC gestito' }

        # --- Notifications, audio, input ------------------------------------------------------------
        @{ Name = 'Notifiche account in Impostazioni'; Category = 'Notifications'; Path = 'Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications'; Key = 'EnableAccountNotifications'; Value = 0; Note = 'Puoi perdere promemoria account e backup' }
        @{ Name = 'Notifiche barra di gioco'; Category = 'Notifications'; Path = $gameBar; Key = 'ShowStartupPanel'; Value = 0; Note = 'Nasconde pannello di avvio Game Bar; dipende dalla versione' }
        @{ Name = 'Notifiche toast Windows'; Category = 'Notifications'; Path = 'Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Key = 'ToastEnabled'; Value = 0; Note = 'Disabilita toast globali; potresti perdere notifiche importanti; mai nei preset' }
        @{ Name = 'Suoni notifiche toast'; Category = 'Audio'; Path = $notifications; Key = 'NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND'; Value = 0; Note = 'Preferenza suono notifiche; non modifica audio dei giochi' }
        @{ Name = 'Comportamento mouse: accelerazione off'; Category = 'Input'; Kind = 'String'; Path = $mouse; Key = 'MouseSpeed'; Value = '0'; Note = 'Solo puntatore Windows, giochi raw input possono ignorarlo' }

        # --- Existing values only (Windows created them: never invent undocumented keys) -------------
        @{ Name = 'Mantieni nascosti file protetti'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'ShowSuperHidden'; Value = 0; Note = "Non mostra file protetti di sistema$build" }
        @{ Name = 'Menu classico quando supportato'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'AlwaysShowMenus'; Value = 1; Note = "Preferenza legacy$build" }
        @{ Name = 'Gestori anteprima Explorer'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'ShowPreviewHandlers'; Value = 1; Note = "Preferenza anteprima$build" }
        @{ Name = 'Navigazione: espandi cartella attuale'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'NavPaneExpandToCurrentFolder'; Value = 1; Note = "Preferenza$build" }
        @{ Name = 'Navigazione: tutte le cartelle'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'NavPaneShowAllFolders'; Value = 1; Note = "Preferenza$build" }
        @{ Name = 'Navigazione: Raccolte'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'NavPaneShowLibraries'; Value = 1; Note = "Preferenza$build" }
        @{ Name = 'Icona tipo su miniature'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'ShowTypeOverlay'; Value = 1; Note = "Preferenza$build" }
        @{ Name = 'Descrizioni cartelle: off'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'FolderContentsInfoTip'; Value = 0; Note = "Riduce informazioni al passaggio mouse$build" }
        @{ Name = 'Dimensioni nei suggerimenti: off'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'ShowFolderSizeTip'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Documenti recenti Jump List: off'; Category = 'Explorer'; ExistingOnly = $true; Path = $adv; Key = 'Start_TrackDocs'; Value = 0; Note = "Non cancella documenti$build" }
        @{ Name = 'Colore accento barra e Start: off'; Category = 'Visual'; ExistingOnly = $true; Path = $personalize; Key = 'ColorPrevalence'; Value = 0; Note = "Preferenza estetica$build" }
        @{ Name = 'Colore accento bordi: off'; Category = 'Visual'; ExistingOnly = $true; Path = 'Software\Microsoft\Windows\DWM'; Key = 'ColorPrevalence'; Value = 0; Note = "Preferenza estetica$build" }
        @{ Name = 'Tastiera touch: predizione off'; Category = 'Input'; ExistingOnly = $true; Path = $tabletTip; Key = 'EnableTextPrediction'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Tastiera touch: autocorrezione off'; Category = 'Input'; ExistingOnly = $true; Path = $tabletTip; Key = 'EnableAutocorrection'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Tastiera touch: ortografia off'; Category = 'Input'; ExistingOnly = $true; Path = $tabletTip; Key = 'EnableSpellchecking'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Tastiera touch: suono off'; Category = 'Input'; ExistingOnly = $true; Path = $tabletTip; Key = 'EnableKeyAudioFeedback'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Tastiera fisica: suggerimenti off'; Category = 'Input'; ExistingOnly = $true; Path = $inputSettings; Key = 'EnableHwkbTextPrediction'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Tastiera fisica: correzione off'; Category = 'Input'; ExistingOnly = $true; Path = $inputSettings; Key = 'EnableHwkbAutocorrection'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Suggerimenti multilingue: off'; Category = 'Input'; ExistingOnly = $true; Path = $inputSettings; Key = 'MultilingualEnabled'; Value = 0; Note = "Preferenza$build" }
        @{ Name = 'Cronologia appunti: off'; Category = 'Privacy'; ExistingOnly = $true; Path = $clipboard; Key = 'EnableClipboardHistory'; Value = 0; Note = "Win+V non disponibile$build" }
        @{ Name = 'Sincronizzazione appunti: off'; Category = 'Privacy'; ExistingOnly = $true; Path = $clipboard; Key = 'EnableCloudClipboard'; Value = 0; Note = "Copia locale resta$build" }
        @{ Name = 'Tasto Xbox non apre Game Bar'; Category = 'Gaming'; ExistingOnly = $true; Path = $gameBar; Key = 'UseNexusForGameBarEnabled'; Value = 0; Note = "Preferenza controller$build" }
        @{ Name = 'Notifiche normali sopra blocco: off'; Category = 'Notifications'; ExistingOnly = $true; Path = $notifications; Key = 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK'; Value = 0; Note = "Privacy schermata blocco$build" }

        # --- Windows 11 taskbar (existing values only) ----------------------------------------------
        @{ Name = 'Badge app barra: off'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'TaskbarBadges'; Value = 0; Note = $taskbarNote }
        @{ Name = 'Lampeggi barra: off'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'TaskbarFlashing'; Value = 0; Note = $taskbarNote }
        @{ Name = 'Barra su tutti gli schermi'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'MMTaskbarEnabled'; Value = 1; Note = $taskbarNote }
        @{ Name = 'Barra secondaria: solo app schermo'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'MMTaskbarMode'; Value = 2; Note = $taskbarNote }
        @{ Name = 'Pulsante Chat legacy: off'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'TaskbarMn'; Value = 0; Note = $taskbarNote }
        @{ Name = 'Pulsante Copilot legacy: off'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'ShowCopilotButton'; Value = 0; Note = $taskbarNote }
        @{ Name = 'Secondi nella barra orologio'; Category = 'Taskbar'; MinBuild = 22000; ExistingOnly = $true; Path = $adv; Key = 'ShowSecondsInSystemClock'; Value = 1; Note = $taskbarNote }

        # --- Mouse, keyboard, desktop (existing string values only) ---------------------------------
        @{ Name = 'Mouse: sensibilita standard'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $mouse; Key = 'MouseSensitivity'; Value = '10'; Note = $stringNote }
        @{ Name = 'Mouse: doppio clic 500 ms'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $mouse; Key = 'DoubleClickSpeed'; Value = '500'; Note = $stringNote }
        @{ Name = 'Mouse: soglia doppio clic X'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $mouse; Key = 'DoubleClickWidth'; Value = '4'; Note = $stringNote }
        @{ Name = 'Mouse: soglia doppio clic Y'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $mouse; Key = 'DoubleClickHeight'; Value = '4'; Note = $stringNote }
        @{ Name = 'Mouse: hover 400 ms'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $mouse; Key = 'MouseHoverTime'; Value = '400'; Note = $stringNote }
        @{ Name = 'Mouse: scorrimento verticale 3'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'WheelScrollLines'; Value = '3'; Note = $stringNote }
        @{ Name = 'Mouse: scorrimento orizzontale 3'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'WheelScrollChars'; Value = '3'; Note = $stringNote }
        @{ Name = 'Tastiera: ripetizione rapida'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $keyboard; Key = 'KeyboardSpeed'; Value = '31'; Note = $stringNote }
        @{ Name = 'Tastiera: ritardo ripetizione medio'; Category = 'Input'; Kind = 'String'; ExistingOnly = $true; Path = $keyboard; Key = 'KeyboardDelay'; Value = '1'; Note = $stringNote }
        @{ Name = 'Desktop: wallpaper centrato'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'WallpaperStyle'; Value = '0'; Note = $stringNote }
        @{ Name = 'Desktop: sfondo non affiancato'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'TileWallpaper'; Value = '0'; Note = $stringNote }
        @{ Name = 'Desktop: trascina mostrando contenuto'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'DragFullWindows'; Value = '1'; Note = $stringNote }
        @{ Name = 'Desktop: cursore lampeggia 530 ms'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'CursorBlinkRate'; Value = '530'; Note = $stringNote }
        @{ Name = 'Desktop: salvaschermo 15 min'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'ScreenSaveTimeOut'; Value = '900'; Note = $stringNote }
        @{ Name = 'Desktop: lampeggio focus 3 volte'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $desktop; Key = 'ForegroundFlashCount'; Value = '3'; Note = $stringNote }
        @{ Name = 'Desktop: bordo standard'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $metrics; Key = 'BorderWidth'; Value = '-15'; Note = $stringNote }
        @{ Name = 'Desktop: bordo aggiuntivo standard'; Category = 'Visual'; Kind = 'String'; ExistingOnly = $true; Path = $metrics; Key = 'PaddedBorderWidth'; Value = '-60'; Note = $stringNote }
    )

    # --- App permissions (personal PCs only; microphone, camera, accessibility are never listed) ---
    $consent = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    $capabilities = [ordered]@{
        activity = 'Attivita fisica'; appDiagnostics = 'Diagnostica altre app'; appointments = 'Calendario'; contacts = 'Contatti'
        email = 'Posta'; chat = 'Messaggi'; userAccountInformation = 'Dati account'; userDataTasks = 'Attivita e promemoria'
        phoneCallHistory = 'Cronologia chiamate'; phoneCall = 'Chiamate'; documentsLibrary = 'Documenti'; musicLibrary = 'Musica'
        picturesLibrary = 'Immagini'; videosLibrary = 'Video'; broadFileSystemAccess = 'Accesso esteso file'; location = 'Posizione'
        userNotificationListener = 'Lettura notifiche da app'; systemAIModels = 'Modelli AI locali'
    }
    foreach ($capability in $capabilities.Keys) {
        @{
            Name = "Permesso app: $($capabilities[$capability]) off"; Category = 'App Privacy'; Kind = 'String'
            Path = "$consent\$capability"; Key = 'Value'; Value = 'Deny'
            ExistingOnly = $true; AllowedBefore = @('Allow', 'Deny'); PersonalOnly = $true
            Note = 'Puo limitare app che usano questa funzione; non blocca tutti i programmi desktop; ripristinabile'
        }
    }
}

function Get-PolicyDefinition {
    <# User policies read from the local Microsoft ADMX templates (personal PCs only). #>
    $personal = 'Criterio utente da ADMX locale; edizione/build e gestione MDM possono limitarne effetto'
    $expansion = 'Criterio utente ADMX locale; dipende da edizione/build; non usare su PC gestiti'
    $both = @('User', 'Both')
    @(
        @{ File = 'CloudContent.admx'; Policy = 'DisableThirdPartySuggestions'; Name = 'Spotlight: suggerimenti terze parti'; Category = 'Debloat'; Note = $personal }
        @{ File = 'CloudContent.admx'; Policy = 'DisableSpotlightCollectionOnDesktop'; Name = 'Spotlight: raccolta sul desktop'; Category = 'Debloat'; Note = $personal }
        @{ File = 'CloudContent.admx'; Policy = 'DisableWindowsSpotlightOnActionCenter'; Name = 'Spotlight: suggerimenti nel centro notifiche'; Category = 'Debloat'; Note = $personal }
        @{ File = 'CloudContent.admx'; Policy = 'DisableWindowsSpotlightOnSettings'; Name = 'Spotlight: suggerimenti in Impostazioni'; Category = 'Debloat'; Note = $personal }
        @{ File = 'CloudContent.admx'; Policy = 'DisableWindowsSpotlightWindowsWelcomeExperience'; Name = 'Spotlight: schermata benvenuto'; Category = 'Debloat'; Note = $personal }
        @{ File = 'CloudContent.admx'; Policy = 'DisableTailoredExperiencesWithDiagnosticData'; Name = 'Policy: esperienze personalizzate'; Category = 'Privacy'; Note = $personal }
        @{ File = 'CloudContent.admx'; Policy = 'DisableWindowsSpotlightFeatures'; Name = 'Spotlight: disabilita tutte le funzioni'; Category = 'Debloat'; Note = $personal }
        @{ File = 'WindowsExplorer.admx'; Policy = 'DisableThumbsDBOnNetworkFolders'; Name = 'Esplora file: cache miniature di rete'; Category = 'Explorer'; Note = $personal }
        @{ File = 'Explorer.admx'; Policy = 'DisableThumbsDBOnNetworkFolders'; Name = 'Esplora file: cache miniature di rete'; Category = 'Explorer'; Note = $personal }
        @{ File = 'Taskbar.admx'; Policy = 'NoBalloonFeatureAdvertisements'; Name = 'Suggerimenti funzionalita barra'; Category = 'Privacy'; Class = $both; Note = $expansion }
        @{ File = 'Taskbar.admx'; Policy = 'NoSystraySystemPromotion'; Name = 'Promozioni area notifiche'; Category = 'Debloat'; Class = $both; Note = $expansion }
        @{ File = 'Taskbar.admx'; Policy = 'TaskbarNoThumbnail'; Name = 'Anteprime barra: off'; Category = 'Taskbar'; Class = $both; Note = $expansion }
        @{ File = 'Taskbar.admx'; Policy = 'NoRemoteDestinations'; Name = 'Destinazioni remote Jump List: off'; Category = 'Privacy'; Class = $both; Note = $expansion }
        @{ File = 'Taskbar.admx'; Policy = 'TurnOffAbbreviatedDateTimeFormat'; Name = 'Data e ora estesa'; Category = 'Taskbar'; Class = $both; Note = $expansion }
        @{ File = 'Taskbar.admx'; Policy = 'AlwaysShowNotificationIcon'; Name = 'Icona notifiche visibile'; Category = 'Taskbar'; Class = $both; Note = $expansion }
        @{ File = 'StartMenu.admx'; Policy = 'ShowRunAsDifferentUserInStart'; Name = 'Mostra Esegui come altro utente'; Category = 'Explorer'; Class = $both; Note = $expansion }
        @{ File = 'StartMenu.admx'; Policy = 'HideCategoryView'; Name = 'Nascondi vista categorie Start'; Category = 'Taskbar'; Class = $both; Note = $expansion }
        @{ File = 'WindowsExplorer.admx'; Policy = 'HideContentViewModeSnippets'; Name = 'Nascondi estratti vista contenuto'; Category = 'Privacy'; Class = $both; Note = $expansion }
        @{ File = 'WindowsExplorer.admx'; Policy = 'NoStrCmpLogical'; Name = 'Ordinamento nomi lessicografico'; Category = 'Explorer'; Class = $both; Note = $expansion }
        @{ File = 'Search.admx'; Policy = 'DisableSearchHistory'; Name = 'Cronologia ricerca criterio utente'; Category = 'Privacy'; Class = $both; Note = $expansion }
        @{ File = 'EdgeUI.admx'; Policy = 'DisableHelpSticker'; Name = 'Suggerimenti interfaccia legacy'; Category = 'Debloat'; Class = $both; Note = $expansion }
        @{ File = 'WindowsCopilot.admx'; Policy = 'TurnOffWindowsCopilot'; Name = 'Copilot Windows legacy: off'; Category = 'Debloat'; Class = $both; Note = $expansion }
        @{ File = 'WindowsCopilot.admx'; Policy = 'DisableAIDataAnalysis'; Name = 'Recall: analisi dati AI off'; Category = 'Privacy'; Class = $both; Note = $expansion }
        @{ File = 'WindowsCopilot.admx'; Policy = 'DisableClickToDo'; Name = 'Click to Do: off'; Category = 'Privacy'; Class = $both; Note = $expansion }
    )
}

function Get-BrowserPolicyDefinition {
    <# Local browser policies, offered only when the browser is installed (personal PCs only). #>
    $common = @(
        @('BackgroundModeEnabled', 0, 'Processi in background dopo chiusura'),
        @('SearchSuggestEnabled', 0, 'Suggerimenti online digitazione'),
        @('NetworkPredictionOptions', 2, 'Precaricamento rete'),
        @('AlternateErrorPagesEnabled', 0, 'Pagine errore alternative online'),
        @('SpellCheckServiceEnabled', 0, 'Controllo ortografico cloud'),
        @('ShowHomeButton', 1, 'Pulsante Home visibile'),
        @('BookmarkBarEnabled', 1, 'Barra preferiti visibile'),
        @('AutofillAddressEnabled', 0, 'Compilazione automatica indirizzi'),
        @('AutofillCreditCardEnabled', 0, 'Compilazione automatica carte'),
        @('TranslateEnabled', 0, 'Traduzione automatica')
    )
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    @(
        @{
            Name = 'Edge'; Key = 'Software\Policies\Microsoft\Edge'; Exe = 'msedge.exe'
            Dirs = @("$env:ProgramFiles\Microsoft\Edge\Application", "$programFilesX86\Microsoft\Edge\Application", "$env:LOCALAPPDATA\Microsoft\Edge\Application")
            Rows = $common + @(
                @('StartupBoostEnabled', 0, 'Avvio anticipato in background'),
                @('PersonalizationReportingEnabled', 0, 'Personalizzazione dati navigazione'),
                @('EdgeShoppingAssistantEnabled', 0, 'Assistente shopping'),
                @('NewTabPageContentEnabled', 0, 'Feed notizie nuova scheda'),
                @('NewTabPagePrerenderEnabled', 0, 'Precaricamento nuova scheda'),
                @('NewTabPageQuickLinksEnabled', 0, 'Collegamenti rapidi nuova scheda'),
                @('ShowRecommendationsEnabled', 0, 'Raccomandazioni funzionalita'),
                @('HubsSidebarEnabled', 0, 'Barra laterale'),
                @('MicrosoftEdgeInsiderPromotionEnabled', 0, 'Promozione Edge Insider'),
                @('EdgeEDropEnabled', 0, 'Condivisione Drop'),
                @('EdgeOpenInSidebarEnabled', 0, 'Apri nella barra laterale'),
                @('EdgeHistoryAISearchEnabled', 0, 'Ricerca AI cronologia'),
                @('MicrosoftEditorSynonymsEnabled', 0, 'Suggerimenti sinonimi cloud'),
                @('MouseGestureEnabled', 0, 'Gesti mouse')
            )
        },
        @{
            Name = 'Chrome'; Key = 'Software\Policies\Google\Chrome'; Exe = 'chrome.exe'
            Dirs = @("$env:ProgramFiles\Google\Chrome\Application", "$programFilesX86\Google\Chrome\Application", "$env:LOCALAPPDATA\Google\Chrome\Application")
            Rows = $common + @(
                @('MetricsReportingEnabled', 0, 'Statistiche utilizzo facoltative'),
                @('PromotionalTabsEnabled', 0, 'Schede promozionali'),
                @('UrlKeyedAnonymizedDataCollectionEnabled', 0, 'Raccolta URL anonimizzati')
            )
        }
    )
}

function Get-PowerDefinition {
    <# AC indexes of the active scheme. Desktop without battery only: never on laptops. #>
    $processor = '54533251-82be-4824-96c1-47b60b740d00'
    $pcie = '501a4d13-42af-4429-9fd1-a8218c268e20'
    $disk = '0012ee47-9041-4b5d-9b77-535fba8b1442'
    $display = '7516b95f-f776-4464-8c53-06167f40cc99'
    $sleep = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    $scope = '; solo piano attivo al momento della scansione, AC'
    @(
        @{ Name = 'CPU: limite massimo 100%'; Subgroup = $processor; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Value = 100; Note = "Rimuove un eventuale limite AC; maggiori consumi possibili$scope" }
        @{ Name = 'CPU: minimo 5%'; Subgroup = $processor; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Value = 5; Note = "Consente idle; utile contro piani bloccati al 100%, non e FPS boost$scope" }
        @{ Name = 'CPU: boost aggressivo'; Subgroup = $processor; Setting = 'be337238-0d82-4146-a960-4f3749d470c7'; Value = 2; Note = "Puo aumentare calore e consumi; misura temperature prima/dopo$scope" }
        @{ Name = 'CPU: preferenza prestazioni EPP 25'; Subgroup = $processor; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Value = 25; Note = "Solo CPPC/HWP compatibile; effetto hardware non garantito$scope" }
        @{ Name = 'PCIe: risparmio link disattivato'; Subgroup = $pcie; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Value = 0; Note = "Opzionale per confronto latenza; maggior consumo a riposo$scope" }
        @{ Name = 'Dischi: nessuno standby AC'; Subgroup = $disk; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Value = 0; Note = "Solo se HDD entra in standby durante attivita; maggior consumo$scope" }
        @{ Name = 'Monitor: spegnimento dopo 20 min'; Subgroup = $display; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Value = 1200; Note = 'Risparmio; non FPS; solo desktop AC' }
        @{ Name = 'Sospensione: dopo 60 min'; Subgroup = $sleep; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Value = 3600; Note = 'Attenzione download e server; solo desktop AC' }
        @{ Name = 'Ibernazione: dopo 180 min'; Subgroup = $sleep; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Value = 10800; Note = 'Solo se ibernazione disponibile; solo desktop AC' }
    )
}

$script:AppNotificationPattern = '(?i)Discord|Spotify|Steam|EpicGames|Battle\.net|Telegram|WhatsApp|Chrome|Firefox|Brave|Vivaldi|Opera|Twitch|Xbox|GameBar|Teams|Outlook|Microsoft\.GamingApp|Medal|Riot|Nexus|CurseForge'
$script:ProtectedNotificationPattern = '(?i)Security|Defender|Update|Firewall'
$script:StartupAllowList = @('Discord', 'Steam', 'Spotify', 'EpicGamesLauncher', 'Epic Games Launcher', 'Battle.net', 'EADM', 'electron.app.CurseForge', 'WallpaperEngine', 'Opera Stable', 'RiotClient', 'electron.app.BlueStacks Services')

#endregion

#region Catalog builder ---------------------------------------------------------------------------

function New-TweakRow {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$Target,
        [string]$Level = 'OptIn',
        [string]$Note = ''
    )
    [pscustomobject]@{
        Name        = $Name
        Category    = $Category
        Path        = $Path
        Key         = $Key
        TargetState = $Target
        Before      = Format-State $Before
        After       = Format-State $Target
        Status      = if (Test-SameState $Before $Target) { $script:StatusConfigured } else { $script:StatusAvailable }
        Level       = $Level
        Note        = $Note
        Selected    = $false
    }
}

function ConvertTo-TweakRow {
    <# Turns one registry definition into a catalog row, or nothing when it does not apply here. #>
    param([Parameter(Mandatory)][hashtable]$Definition, [Parameter(Mandatory)]$Context)
    $kind = if ($Definition.Kind) { $Definition.Kind } else { 'DWord' }
    if ($Definition.MinBuild -and $Context.Build -lt $Definition.MinBuild) { return }
    if ($Definition.PersonalOnly -and $Context.IsDomainJoined) { return }
    $before = Get-TweakValue -Path $Definition.Path -Key $Definition.Key
    if ($before.Exists -and $before.Kind -ne $kind) { return }
    if ($Definition.ExistingOnly -and -not $before.Exists) { return }
    if ($Definition.AllowedBefore -and [string]$before.Value -notin $Definition.AllowedBefore) { return }
    $value = if ($kind -eq 'DWord') { [int]$Definition.Value } else { [string]$Definition.Value }
    $level = if ($Definition.Level) { $Definition.Level } else { 'OptIn' }
    New-TweakRow -Name $Definition.Name -Category $Definition.Category -Path $Definition.Path -Key $Definition.Key `
        -Before $before -Target (New-ValueState -Exists $true -Kind $kind -Value $value) -Level $level -Note $Definition.Note
}

function Get-PolicyTweakRow {
    param([Parameter(Mandatory)]$Context)
    if ($Context.IsDomainJoined) { return }
    foreach ($definition in Get-PolicyDefinition) {
        try {
            $class = if ($definition.Class) { $definition.Class } else { @('User') }
            $policy = Get-AdmxUserPolicy -File $definition.File -Name $definition.Policy -Class $class
            if (-not $policy) { continue }
            ConvertTo-TweakRow -Context $Context -Definition @{
                Name = $definition.Name; Category = $definition.Category; Path = $policy.Key; Key = $policy.ValueName
                Value = $policy.Value; Note = $definition.Note
            }
        } catch {
            Write-Verbose "Criterio ignorato $($definition.Policy): $($_.Exception.Message)"
        }
    }
}

function Get-BrowserTweakRow {
    param([Parameter(Mandatory)]$Context)
    if ($Context.IsDomainJoined) { return }
    foreach ($browser in Get-BrowserPolicyDefinition) {
        if (-not (Test-BrowserInstalled -Executable $browser.Exe -Directory $browser.Dirs)) { continue }
        foreach ($row in $browser.Rows) {
            ConvertTo-TweakRow -Context $Context -Definition @{
                Name = "$($browser.Name): $($row[2])"; Category = 'Browser'; Path = $browser.Key; Key = $row[0]; Value = $row[1]
                Note = 'Criterio locale; puo mostrare Gestito dalla tua organizzazione. Richiede riavvio browser; non tocca sicurezza o aggiornamenti'
            }
        }
    }
}

function Get-PowerTweakRow {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.IsDesktopOnAc) { return }
    try {
        $plan = Get-ActivePowerScheme
    } catch {
        Write-Verbose "Piano energetico non leggibile: $($_.Exception.Message)"
        return
    }
    foreach ($definition in Get-PowerDefinition) {
        $path = "POWER|$plan|$($definition.Subgroup)"
        try {
            $before = Get-TweakValue -Path $path -Key $definition.Setting
            New-TweakRow -Name $definition.Name -Category 'Power / CPU' -Path $path -Key $definition.Setting -Before $before `
                -Target (New-ValueState -Exists $true -Kind 'DWord' -Value ([int]$definition.Value)) -Note $definition.Note
        } catch {
            Write-Verbose "Impostazione energia non disponibile: $($definition.Name)"
        }
    }
}

function Get-AppNotificationTweakRow {
    param([Parameter(Mandatory)]$Context)
    $root = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    foreach ($app in @(Get-UserRegistrySubKeyName -Path $root)) {
        if ($app -notmatch $script:AppNotificationPattern -or $app -match $script:ProtectedNotificationPattern) { continue }
        ConvertTo-TweakRow -Context $Context -Definition @{
            Name = "Notifiche app: $app"; Category = 'App Notifications'; Path = "$root\$app"; Key = 'Enabled'; Value = 0
            Note = 'Disattiva notifiche di questa app; potresti perdere messaggi; non disinstalla'
        }
    }
}

function Get-StartupTweakRow {
    <# Run-key entries of known launchers. The target state is "value removed"; backup restores it. #>
    param([object[]]$Records = @())
    $run = 'Software\Microsoft\Windows\CurrentVersion\Run'
    foreach ($name in $script:StartupAllowList) {
        $before = Get-TweakValue -Path $run -Key $name
        $managed = $null -ne (@($Records | Where-Object { $_.Path -eq $run -and $_.Key -eq $name -and -not $_.Target.Exists }) | Select-Object -First 1)
        $isLaunchEntry = $before.Exists -and $before.Kind -in @('String', 'ExpandString')
        if (-not $isLaunchEntry -and -not (-not $before.Exists -and $managed)) { continue }
        [pscustomobject]@{
            Name        = "Avvio: $name"
            Category    = 'Startup'
            Path        = $run
            Key         = $name
            TargetState = New-ValueState
            Before      = if ($before.Exists) { 'Attivo in Run' } else { 'Assente in Run' }
            After       = 'Rimosso da Run'
            Status      = if ($before.Exists) { $script:StatusAvailable } else { $script:StatusConfigured }
            Level       = 'OptIn'
            Note        = 'App resta installata; non chiude processi; avvio automatico da altre fonti possibile'
            Selected    = $false
        }
    }
}

function Get-PwuRating {
    <# PWU = qualitative potential impact (Low/Medium/High). Not a benchmark, not an FPS figure. #>
    param([Parameter(Mandatory)]$Row)
    $rank = 1
    $why = 'Preferenza, privacy o usabilita; impatto prestazioni generalmente minimo o non misurato.'
    if ($Row.Category -eq 'Startup') {
        $rank = 2
        $why = 'Potenziale risparmio di RAM/CPU e tempo di avvio se questa app parte e resta attiva. Non chiude processi gia aperti.'
    } elseif ($Row.Category -eq 'Gaming' -and $Row.Key -in @('AutoGameModeEnabled', 'AppCaptureEnabled', 'GameDVR_Enabled')) {
        $rank = 2
        $why = 'Possibile beneficio durante il gioco, soprattutto se la cattura in background e realmente attiva; dipende dal carico.'
    } elseif ($Row.Category -eq 'Browser' -and $Row.Key -in @('BackgroundModeEnabled', 'StartupBoostEnabled', 'NetworkPredictionOptions', 'NewTabPagePrerenderEnabled')) {
        $rank = 2
        $why = 'Possibile riduzione dei processi o del precaricamento del browser; dipende da utilizzo e RAM.'
    } elseif ($Row.Path.StartsWith('POWER|')) {
        if ($Row.Key -eq 'bc5038f7-23e0-4960-96da-33abaf5935ec') {
            $limit = 0
            if ([int]::TryParse([string]$Row.Before, [ref]$limit) -and $limit -le 80 -and $limit -gt 0) {
                $rank = 3
                $why = 'Potenziale elevato se la CPU e limitata a 80% o meno e il carico e CPU-bound; maggior calore e consumo. Non e una misura FPS.'
            } else {
                $rank = 2
                $why = 'Rimuove un eventuale limite CPU; beneficio solo se il limite riduce le prestazioni.'
            }
        } elseif ($Row.Key -in @('be337238-0d82-4146-a960-4f3749d470c7', '36687f9e-e3a5-4dbf-b1dc-15eb381c6863')) {
            $rank = 2
            $why = 'Possibile variazione di reattivita CPU; dipende da hardware, firmware e temperature. Puo aumentare i consumi.'
        } else {
            $why = 'Preferenza energetica o risparmio; beneficio prestazioni non garantito e possibili consumi maggiori.'
        }
    } elseif ($Row.Key -in @('EnableTransparency', 'TaskbarAnimations', 'MinAnimate', 'IconsOnly', 'ShowPreviewHandlers')) {
        $why = 'Riduce o modifica effetti della shell; impatto soprattutto sulla UI, non sugli FPS del gioco.'
    }
    [pscustomobject]@{ Rank = $rank; Label = @('', 'Low', 'Medium', 'High')[$rank]; Reason = $why }
}

function Get-TweakCatalog {
    <#
        Builds every applicable row for this PC. A definition that fails to read is skipped instead of
        aborting the whole scan, and Path+Key duplicates are dropped (first definition wins).
    #>
    $context = Get-SystemContext
    $records = @()
    try { $records = @(Read-Journal -Journal $script:UserJournal) } catch { $records = @() }

    $raw = @(
        foreach ($definition in Get-StaticTweakDefinition) {
            try { ConvertTo-TweakRow -Definition $definition -Context $context } catch { Write-Verbose "Voce ignorata $($definition.Key): $($_.Exception.Message)" }
        }
        Get-PolicyTweakRow -Context $context
        try { Get-BrowserTweakRow -Context $context } catch { Write-Verbose "Browser ignorati: $($_.Exception.Message)" }
        Get-PowerTweakRow -Context $context
        try { Get-AppNotificationTweakRow -Context $context } catch { Write-Verbose "Notifiche ignorate: $($_.Exception.Message)" }
        try { Get-StartupTweakRow -Records $records } catch { Write-Verbose "Avvio ignorato: $($_.Exception.Message)" }
    )
    $seen = @{}
    foreach ($row in $raw) {
        $id = ('{0}|{1}' -f $row.Path, $row.Key).ToUpperInvariant()
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $pwu = Get-PwuRating -Row $row
        $row | Add-Member -NotePropertyName PWU -NotePropertyValue $pwu.Label -Force
        $row | Add-Member -NotePropertyName PWURank -NotePropertyValue $pwu.Rank -Force
        $row | Add-Member -NotePropertyName PWUReason -NotePropertyValue $pwu.Reason -Force
        $row
    }
}

function Get-NetworkTweakRow {
    <# Whitelisted advanced properties of physical adapters that are up and support the target. #>
    $definitions = Get-NetworkDefinition
    $hasBattery = (Get-SystemContext).HasBattery
    foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        if ($adapter.Status -ne 'Up') { continue }
        foreach ($property in @(Get-NetAdapterAdvancedProperty -Name ([WildcardPattern]::Escape($adapter.Name)) -ErrorAction SilentlyContinue)) {
            $key = $property.RegistryKeyword
            if (-not $definitions.ContainsKey($key) -or @($property.RegistryValue).Count -ne 1) { continue }
            if ($key -in @('*SelectiveSuspend', '*PacketCoalescing') -and $hasBattery) { continue }
            $definition = $definitions[$key]
            $valid = @($property.ValidRegistryValues)
            $before = [string]$property.RegistryValue[0]
            if ($definition[1] -notin $valid -or $before -notin $valid) { continue }
            [pscustomobject]@{
                Name        = "$($adapter.Name): $($definition[0])"
                Path        = "NET|$([guid]$adapter.InterfaceGuid)"
                Key         = $key
                Before      = $before
                After       = $definition[1]
                Status      = if ($before -eq $definition[1]) { $script:StatusConfigured } else { $script:StatusAvailable }
                PWU         = $definition[2]
                Note        = $definition[3] + ' | Admin richiesto; effetto dopo riavvio scheda/PC.'
                TargetState = New-ValueState -Exists $true -Kind 'String' -Value ([string]$definition[1])
            }
        }
    }
}

#endregion

#region Row state: verification labels and allowed actions ----------------------------------------

function Get-VerificationLabel {
    <# Re-reads the live value of a row and compares it with its backup record (if any). #>
    param([Parameter(Mandatory)]$Row, [object[]]$Records = @(), [bool]$Valid = $true, $Boot = $null)
    if (-not $Valid) { return $script:Label.InvalidBackup }
    $record = Find-JournalRecord -Records $Records -Path $Row.Path -Key $Row.Key
    if (-not $record) { return $Row.Status }
    try {
        $actual = Get-TweakValue -Path $Row.Path -Key $Row.Key
        if (-not (Test-SameState $actual $record.Target)) {
            if (Test-SameState $actual $record.Old) { return $script:Label.Original }
            return $script:Label.Drift
        }
        if (-not (Test-SameState $actual $Row.TargetState)) { return $script:Label.TargetChanged }
        if ($Row.Path.StartsWith('NET|')) {
            # Driver values are only live after an adapter/PC restart that happened after the change.
            if ($Boot -and (ConvertTo-UtcTime $Boot) -gt (ConvertTo-UtcTime $record.Time)) { return $script:Label.RebootVerified }
            return $script:Label.RebootPending
        }
        if ($Row.Category -eq 'Browser' -or $Row.Path -match '^Software\\Policies\\(Microsoft\\Edge|Google\\Chrome)') { return $script:Label.RestartApp }
        if ($Row.Path.StartsWith('POWER|')) { return $script:Label.PowerActive }
        $script:Label.Verified
    } catch {
        $script:Label.ReadError
    }
}

function Set-RowActionFlag {
    <# CanApply / CanRestore / CanSelect / SelectionHint, derived from status, backup and access. #>
    param([Parameter(Mandatory)]$Row, [object[]]$Records = @(), [bool]$Valid = $true)
    $record = Find-JournalRecord -Records $Records -Path $Row.Path -Key $Row.Key
    $apply = $Valid -and -not $record -and $Row.Status -eq $script:StatusAvailable
    $needsAdmin = $apply -and -not (Test-TweakWritable -Row $Row)
    if ($needsAdmin) {
        $apply = $false
        $Row | Add-Member -NotePropertyName VerifiedStatus -NotePropertyValue $script:Label.NeedsAdmin -Force
    }
    $restore = $Valid -and $null -ne $record -and $Row.VerifiedStatus -notin $script:BlockingLabels
    $hint = if ($apply) { 'Seleziona per applicare' }
    elseif ($restore) { 'Ripristina valore originale o chiudi backup se gia originale' }
    elseif ($needsAdmin) { 'Chiave protetta (criteri): avvia PowerShell come amministratore per applicarla' }
    elseif ($record) { 'Conflitto o errore: consulta Backup / Recovery' }
    else { 'Gia configurato senza backup; non modificabile automaticamente' }
    $Row | Add-Member -NotePropertyName CanApply -NotePropertyValue ([bool]$apply) -Force
    $Row | Add-Member -NotePropertyName CanRestore -NotePropertyValue ([bool]$restore) -Force
    $Row | Add-Member -NotePropertyName CanSelect -NotePropertyValue ([bool]($apply -or $restore)) -Force
    $Row | Add-Member -NotePropertyName SelectionHint -NotePropertyValue $hint -Force
}

function Set-VerificationState {
    <# Adds VerifiedStatus and action flags to every row, reading the matching journal once. #>
    param([object[]]$Rows, $Boot = $null)
    $cache = @{}
    foreach ($row in @($Rows)) {
        $journal = Get-JournalFor -Path $row.Path
        if (-not $cache.ContainsKey($journal.Name)) {
            try {
                $cache[$journal.Name] = [pscustomobject]@{ Valid = $true; Records = @(Read-Journal -Journal $journal) }
            } catch {
                $cache[$journal.Name] = [pscustomobject]@{ Valid = $false; Records = @() }
            }
        }
        $state = $cache[$journal.Name]
        $label = Get-VerificationLabel -Row $row -Records $state.Records -Valid $state.Valid -Boot $Boot
        $row | Add-Member -NotePropertyName VerifiedStatus -NotePropertyValue $label -Force
        Set-RowActionFlag -Row $row -Records $state.Records -Valid $state.Valid
    }
}

function Test-ApplyChoice {
    param($Row)
    if ($Row.PSObject.Properties['CanApply']) { return [bool]$Row.CanApply }
    $Row.Status -eq $script:StatusAvailable -and (-not $Row.PSObject.Properties['CanSelect'] -or $Row.CanSelect)
}

function Test-RestoreChoice {
    param($Row)
    [bool]$Row.CanRestore
}

function Get-SelectionMap {
    <# Remembers which rows were selected for apply or restore, to survive a refresh. #>
    param([object[]]$Rows)
    $map = @{}
    foreach ($row in @($Rows)) {
        if ($row.Selected) {
            $map['{0}|{1}' -f $row.Path, $row.Key] = if (Test-ApplyChoice $row) { 'Apply' } elseif (Test-RestoreChoice $row) { 'Restore' } else { '' }
        }
    }
    $map
}

function Restore-SelectionMap {
    <# Re-selects a row only when the same action is still possible (never apply -> restore). #>
    param([object[]]$Rows, [hashtable]$Map)
    foreach ($row in @($Rows)) {
        $choice = $Map['{0}|{1}' -f $row.Path, $row.Key]
        $row.Selected = (($choice -eq 'Apply' -and (Test-ApplyChoice $row)) -or ($choice -eq 'Restore' -and (Test-RestoreChoice $row)))
    }
}

#endregion

#region Portable profiles -------------------------------------------------------------------------
# v2 IDs are hashes of (target identity + target state): no registry values, adapter GUIDs,
# executable paths or backups ever leave the PC. A profile only SELECTS compatible rows.

function Get-LegacyProfileId {
    param([Parameter(Mandatory)]$Row)
    if ($Row.Path.StartsWith('POWER|')) { 'POWER|{0}|{1}' -f $Row.Path.Split('|')[2], $Row.Key } else { '{0}|{1}' -f $Row.Path, $Row.Key }
}

function Get-PortableProfileId {
    param([Parameter(Mandatory)]$Row)
    if ($Row.Category -in @('App Notifications', 'GPU')) { return }
    $id = if ($Row.Path.StartsWith('NET|')) { 'NET|' + $Row.Key } else { Get-LegacyProfileId $Row }
    $state = $Row.TargetState
    'T-' + (Get-Sha256Hex ('{0}|{1}|{2}|{3}' -f $id.ToUpperInvariant(), $state.Exists, $state.Kind, [string]$state.Value)).Substring(0, 32)
}

function New-PortableProfile {
    param([object[]]$General, [object[]]$Network, [switch]$SelectedOnly)
    $ids = @(foreach ($row in @($General) + @($Network)) {
            if (-not $row) { continue }
            if ($SelectedOnly) {
                if (-not $row.Selected -or -not (Test-ApplyChoice $row)) { continue }
            } else {
                try {
                    if (-not (Test-SameState (Get-TweakValue -Path $row.Path -Key $row.Key) $row.TargetState)) { continue }
                } catch {
                    continue
                }
            }
            Get-PortableProfileId $row
        })
    [ordered]@{ Format = 'BrabusPreset'; Version = 2; Selections = @($ids | Sort-Object -Unique) }
}

function Resolve-PortableProfile {
    <# Validates an imported profile and maps its IDs onto this PC's rows (unknown/ambiguous skipped). #>
    param([Parameter(Mandatory)]$Document, [object[]]$General, [object[]]$Network)
    if ($Document.Format -ne 'BrabusPreset' -or $Document.Version -notin @(1, 2)) { throw 'Formato profilo non valido' }
    $ids = @($Document.Selections)
    if ($ids.Count -gt 2000) { throw 'Profilo troppo grande' }
    foreach ($id in $ids) {
        if ($id -isnot [string] -or $id.Length -gt 512 -or ($Document.Version -eq 2 -and $id -notmatch '^T-[A-F0-9]{32}$')) {
            throw 'Identificatore profilo non valido'
        }
    }
    $ids = @($ids | Sort-Object -Unique)
    $index = @{}
    foreach ($row in @($General) + @($Network)) {
        if (-not $row) { continue }
        $candidate = if ($Document.Version -eq 2) { Get-PortableProfileId $row } elseif (-not $row.Path.StartsWith('NET|')) { Get-LegacyProfileId $row }
        if (-not $candidate) { continue }
        if (-not $index.ContainsKey($candidate)) { $index[$candidate] = @() }
        $index[$candidate] += $row
    }
    $found = @()
    $unknown = 0
    $ambiguous = 0
    foreach ($id in $ids) {
        if (-not $index.ContainsKey($id)) { $unknown++; continue }
        $candidates = @($index[$id])
        if ($candidates.Count -gt 1) { $ambiguous++; continue }
        $found += $candidates[0]
    }
    [pscustomobject]@{
        Matches   = $found
        Unknown   = $unknown
        Ambiguous = $ambiguous
        Already   = @($found | Where-Object Status -EQ $script:StatusConfigured).Count
        Eligible  = @($found | Where-Object { Test-ApplyChoice $_ })
    }
}

#endregion

#region Inventory, scan and diagnostics (read-only) ----------------------------------------------

function Get-SoftwareCatalog {
    <# WinGet candidates. Each ID is re-validated against this list and checked live before install. #>
    $raw = @'
Browser|Firefox|Mozilla.Firefox
Browser|Brave|Brave.Brave
Browser|Chrome|Google.Chrome
Browser|Vivaldi|Vivaldi.Vivaldi
Gaming|Steam|Valve.Steam
Gaming|Epic Games Launcher|EpicGames.EpicGamesLauncher
Gaming|Discord|Discord.Discord
Gaming|OBS Studio|OBSProject.OBSStudio
Gaming|Heroic Games Launcher|HeroicGamesLauncher.HeroicGamesLauncher
Gaming|Playnite|Playnite.Playnite
Gaming|MSI Afterburner|Guru3D.Afterburner
Media|VLC|VideoLAN.VLC
Media|Audacity|Audacity.Audacity
Media|HandBrake|HandBrake.HandBrake
Media|foobar2000|PeterPawlowski.foobar2000
Utility|7-Zip|7zip.7zip
Utility|PowerToys|Microsoft.PowerToys
Utility|Everything|voidtools.Everything
Utility|TreeSize Free|JAMSoftware.TreeSize.Free
Utility|Notepad++|Notepad++.Notepad++
Utility|CrystalDiskInfo|CrystalDewWorld.CrystalDiskInfo
Utility|WinDirStat|WinDirStat.WinDirStat
Utility|HWiNFO|REALiX.HWiNFO
Utility|CPU-Z|CPUID.CPU-Z
Utility|GPU-Z|TechPowerUp.GPU-Z
Office|LibreOffice|TheDocumentFoundation.LibreOffice
Office|SumatraPDF|SumatraPDF.SumatraPDF
Office|PDF24|geeksoftwareGmbH.PDF24Creator
Development|Git|Git.Git
Development|Visual Studio Code|Microsoft.VisualStudioCode
Development|PowerShell|Microsoft.PowerShell
Development|Python 3.13|Python.Python.3.13
Development|Node.js LTS|OpenJS.NodeJS.LTS
Development|Windows Terminal|Microsoft.WindowsTerminal
Creative|GIMP|GIMP.GIMP.3
Creative|Krita|KDE.Krita
Creative|Blender|BlenderFoundation.Blender
Creative|Paint.NET|dotPDN.PaintDotNet
Communication|Telegram|Telegram.TelegramDesktop
Communication|Signal|OpenWhisperSystems.Signal
Communication|Zoom|Zoom.Zoom
'@
    foreach ($line in ($raw -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        $parts = $line.Split('|')
        [pscustomobject]@{ Category = $parts[0]; Name = $parts[1]; Id = $parts[2]; Label = "$($parts[0])  |  $($parts[1])  [$($parts[2])]" }
    }
}

function Test-SoftwareId {
    param([string]$Id)
    $Id -match '^[A-Za-z0-9][A-Za-z0-9._+-]{1,99}$' -and $Id -in @(Get-SoftwareCatalog | ForEach-Object Id)
}

function Get-OptionalPackage {
    <# Store apps that may be removed for the current user. Anything not listed is never offered. #>
    $allow = @(
        'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.WindowsFeedbackHub',
        'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.WindowsMaps', 'Microsoft.MicrosoftOfficeHub', 'Clipchamp.Clipchamp',
        'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'MSTeams', 'Microsoft.Todos', 'Microsoft.YourPhone', 'Microsoft.WindowsSoundRecorder',
        'Microsoft.WindowsAlarms', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Windows.DevHome', 'Microsoft.MicrosoftStickyNotes',
        'MicrosoftCorporationII.QuickAssist', 'Microsoft.Copilot', 'Microsoft.BingSearch', 'Microsoft.Microsoft3DViewer', 'Microsoft.MSPaint',
        'Microsoft.MixedReality.Portal', 'Microsoft.Print3D', 'Microsoft.SkypeApp', 'Microsoft.People', 'Microsoft.WindowsCamera',
        'Microsoft.Windows.Photos', 'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.WindowsReadingList'
    )
    @(Get-AppxPackage | Where-Object { $_.Name -in $allow -and -not $_.IsFramework -and -not $_.NonRemovable } | Sort-Object Name)
}

function Get-FeatureInventory {
    @(Get-CimInstance Win32_OptionalFeature -ErrorAction Stop | ForEach-Object {
            $state = switch ([int]$_.InstallState) { 1 { 'Abilitata' } 2 { 'Disabilitata' } 3 { 'Assente' } default { 'Sconosciuta' } }
            [pscustomobject]@{ Name = $_.Name; State = $state; Label = "$state  |  $($_.Name)" }
        } | Sort-Object Name)
}

function Get-ServiceInventory {
    @(Get-CimInstance Win32_Service | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; State = $_.State; StartMode = $_.StartMode; Label = "$($_.StartMode) / $($_.State)  |  $($_.DisplayName) [$($_.Name)]" }
        } | Sort-Object Label)
}

function Get-ActivePowerSchemeText {
    try { Invoke-PowerCfg -ArgumentList '/getactivescheme' } catch { "Non disponibile: $($_.Exception.Message)" }
}

function Get-SystemInventory {
    $os = Get-CimInstance Win32_OperatingSystem
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{
            Drive   = $_.DeviceID
            FreeGiB = [math]::Round($_.FreeSpace / 1GB, 1)
            FreePct = [math]::Round(100 * $_.FreeSpace / [math]::Max([double]1, [double]$_.Size), 1)
        }
    }
    [ordered]@{
        Time         = (Get-Date).ToString('o')
        Windows      = $os.Caption
        Build        = $os.BuildNumber
        CPU          = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        GPU          = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, CurrentRefreshRate)
        RAMGiB       = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        FreeRAMGiB   = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        PowerPlan    = Get-ActivePowerSchemeText
        Disks        = @($disks)
        Startup      = @(Get-CimInstance Win32_StartupCommand | Select-Object Name, Location)
        HeavyRAM     = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 12 ProcessName, WorkingSet64)
        OptionalApps = @(Get-AppxPackage | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable } | Select-Object Name, PackageFullName)
        Network      = @(Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, LinkSpeed)
        Notes        = 'Analisi locale; non identifica da sola colli di bottiglia o incremento FPS.'
    }
}

function Save-ScanReport {
    $items = @(Get-TweakCatalog)
    $file = Join-Path $script:Paths.Root ('scan-' + [guid]::NewGuid().ToString() + '.json')
    Save-JsonFile -Path $file -InputObject @{
        Inventory = Get-SystemInventory
        Findings  = @($items | Select-Object Name, Category, Before, After, Status, PWU, PWUReason, Note)
    }
    $file
}

function Get-ExtendedDiagnostic {
    $out = [ordered]@{}
    $out.Power = Get-ActivePowerSchemeText
    $out.Adapter = @(Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, LinkSpeed, InterfaceDescription)
    $out.DNS = @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, AddressFamily, ServerAddresses)
    $out.NetworkCounters = @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Select-Object Name, ReceivedDiscardedPackets, ReceivedPacketErrors, OutboundDiscardedPackets, OutboundPacketErrors)
    $out.Storage = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus, Size)
    $out.GPU = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, CurrentRefreshRate)
    $out.DriverIssues = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue | Select-Object Name, ConfigManagerErrorCode)
    $out.Audio = @(Get-CimInstance Win32_SoundDevice | Select-Object Name, Status)
    $out.UpdateService = @(Get-Service wuauserv, BITS, DoSvc -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)
    $out.Features = @(Get-FeatureInventory | Select-Object Name, State)
    $out.Services = @(Get-ServiceInventory | Group-Object StartMode | Select-Object Name, Count)
    $out.Note = 'Counters are cumulative snapshots; no conclusion about bottlenecks or latency from these alone.'
    $out
}

function Save-ExtendedDiagnostic {
    $file = Join-Path $script:Paths.Root ('extended-' + [guid]::NewGuid().ToString() + '.json')
    Save-JsonFile -Path $file -InputObject (Get-ExtendedDiagnostic)
    $file
}

function Get-InstalledAppRow {
    $seen = @{}
    $roots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        foreach ($app in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
            if (-not $app.DisplayName -or $app.SystemComponent -eq 1) { continue }
            $id = "$($app.DisplayName)|$($app.DisplayVersion)"
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            New-PageRow -Name $app.DisplayName -State $app.DisplayVersion -Detail $app.Publisher
        }
    }
    foreach ($app in @(Get-AppxPackage | Where-Object { -not $_.IsFramework })) {
        New-PageRow -Name $app.Name -State $app.Version -Detail 'App Microsoft Store / utente corrente'
    }
}

function New-PageRow {
    param($Name, $State, $Detail, $Id = '')
    [pscustomobject]@{ Name = [string]$Name; State = [string]$State; Detail = [string]$Detail; Id = [string]$Id }
}

#endregion

#region Integrity audit ---------------------------------------------------------------------------

function Get-AuditRow {
    param([Parameter(Mandatory)]$Record, [string]$Kind, $Boot)
    $state = 'ERRORE LETTURA'
    $detail = ''
    try {
        $value = Get-TweakValue -Path $Record.Path -Key $Record.Key
        if (Test-SameState $value $Record.Target) {
            $pendingReboot = $Kind -eq 'Driver' -and (-not $Boot -or (ConvertTo-UtcTime $Boot) -le (ConvertTo-UtcTime $Record.Time))
            $state = if ($pendingReboot) { 'RIAVVIO NECESSARIO' } else { 'VALORE VERIFICATO' }
            $detail = "Attuale: $(Format-State $value) | Obiettivo: $(Format-State $Record.Target) | Originale: $(Format-State $Record.Old)"
        } elseif (Test-SameState $value $Record.Old) {
            $state = 'VALORE ORIGINALE'
            $detail = 'Backup presente, valore gia originale.'
        } else {
            $state = 'CONFLITTO'
            $detail = "Attuale: $(Format-State $value) | Obiettivo: $(Format-State $Record.Target) | Non sovrascrivere automaticamente"
        }
    } catch {
        $detail = $_.Exception.Message
    }
    [pscustomobject]@{ Name = $Record.Name; State = $state; Detail = $detail; Kind = $Kind; Id = $Record.Id }
}

function Get-ReleaseAudit {
    <# Read-only integrity report: every active backup record compared with the live value. #>
    $boot = $null
    try { $boot = (Get-SystemContext).LastBoot } catch { $boot = $null }
    foreach ($entry in @(@('Utente / energia', $script:UserJournal), @('Driver', $script:NetworkJournal))) {
        $kind = $entry[0]
        $journal = $entry[1]
        try {
            $records = @(Read-Journal -Journal $journal)
            $state = if ($journal.Warning) { 'ATTENZIONE' } else { 'LEGGIBILE' }
            New-PageRow -Name ('Backup ' + $kind) -State $state -Detail ("$($records.Count) record | " + $journal.Warning)
            foreach ($record in $records) { Get-AuditRow -Record $record -Kind $kind -Boot $boot }
        } catch {
            New-PageRow -Name ('Backup ' + $kind) -State 'ERRORE' -Detail $_.Exception.Message
        }
    }
}

function Invoke-ReleaseCheck {
    <# -ReleaseCheck / -ExportCurrentProfile: JSON summary, optional export to a NEW file. #>
    param([string]$ExportPath)
    $all = @(Get-TweakCatalog)
    Set-VerificationState -Rows $all
    $network = @(Get-NetworkTweakRow)
    $audit = @(Get-ReleaseAudit)
    $document = New-PortableProfile -General $all -Network $network
    $resolved = Resolve-PortableProfile -Document $document -General $all -Network $network
    [ordered]@{
        Version              = $script:AppVersion
        General              = $all.Count
        GeneralConfigured    = @($all | Where-Object Status -EQ $script:StatusConfigured).Count
        GeneralAvailable     = @($all | Where-Object { Test-ApplyChoice $_ }).Count
        GeneralNeedAdmin     = @($all | Where-Object VerifiedStatus -EQ $script:Label.NeedsAdmin).Count
        OriginalBackupNames  = @($audit | Where-Object State -EQ 'VALORE ORIGINALE' | ForEach-Object Name)
        Network              = $network.Count
        NetworkConfigured    = @($network | Where-Object Status -EQ $script:StatusConfigured).Count
        AuditStates          = @($audit | Group-Object State | ForEach-Object { @{ State = $_.Name; Count = $_.Count } })
        ProfileIds           = $document.Selections.Count
        ProfileMatched       = $resolved.Matches.Count
        ProfileAmbiguous     = $resolved.Ambiguous
        Admin                = $script:IsAdmin
    } | ConvertTo-Json -Depth 6
    if ($ExportPath) {
        $target = Get-FullPath $ExportPath
        if (Test-Path -LiteralPath $target) { throw 'File profilo esistente: non sovrascritto' }
        Save-JsonFile -Path $target -InputObject $document
        $readBack = Read-JsonFile -Path $target -MaxBytes 1MB
        if (@($readBack.Selections).Count -ne $document.Selections.Count) { throw 'Verifica export fallita' }
        Write-Output "PROFILE EXPORTED: $target"
    }
}

#endregion

#region Network speed lab -------------------------------------------------------------------------

function Measure-Connection {
    <#
        Runs in a background runspace: it must stay self-contained (no calls to script functions).
        Idle ICMP latency/jitter/loss, then download and upload phases (two HTTPS streams each,
        capped in time and bytes) with ICMP latency sampled under load. Results go into $state.
    #>
    param([hashtable]$state, [int]$phaseSeconds = 14)
    $ErrorActionPreference = 'Stop'
    $state.Method = 'Cloudflare-HTTPS-2stream-14s-v2'
    $total = [Diagnostics.Stopwatch]::StartNew()
    $cancel = $state.CancelSource
    if (-not $cancel) { $cancel = New-Object Threading.CancellationTokenSource }
    $token = $cancel.Token

    $state.Stage = 'LATENZA'
    $state.Progress = 0
    $samples = @()
    $lost = 0
    $ping = New-Object Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt 10; $i++) {
            $token.ThrowIfCancellationRequested()
            try {
                $reply = $ping.Send('1.1.1.1', 700)
                if ($reply.Status -eq 'Success') { $samples += [double]$reply.RoundtripTime } else { $lost++ }
            } catch {
                $lost++
            }
            $state.Samples = @($samples)
            $state.Progress = ($i + 1) * 1.5
            Start-Sleep -Milliseconds 200
        }
    } finally {
        $ping.Dispose()
    }
    $state.Loss = $lost * 10
    if ($samples.Count) { $state.Ping = [math]::Round(($samples | Measure-Object -Average).Average, 1) }
    if ($samples.Count -ge 2) {
        $delta = @(for ($i = 1; $i -lt $samples.Count; $i++) { [math]::Abs($samples[$i] - $samples[$i - 1]) })
        $state.Jitter = [math]::Round(($delta | Measure-Object -Average).Average, 1)
    }

    Add-Type -AssemblyName System.Net.Http
    if (-not ('BrabusSpeedPhaseV2' -as [type])) {
        $source = @'
using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.Security.Cryptography;

public sealed class BrabusSpeedPhaseV2 {
    long count, reserved;
    int requests, failed;
    string error;
    readonly long cap;
    readonly bool down;
    readonly int seconds;
    public readonly Stopwatch Clock = new Stopwatch();
    public long Bytes { get { return Interlocked.Read(ref count); } }
    public int Requests { get { return Volatile.Read(ref requests); } }
    public bool Limited { get { return Interlocked.Read(ref reserved) >= cap; } }
    public string Error { get { return error; } }

    public BrabusSpeedPhaseV2(bool download, long limit, int duration) { down = download; cap = limit; seconds = duration; }

    public async Task Run(CancellationToken external) {
        using (var cts = CancellationTokenSource.CreateLinkedTokenSource(external)) {
            Clock.Start();
            cts.CancelAfter(seconds * 1000);
            try { await Task.WhenAll(Worker(cts), Worker(cts)).ConfigureAwait(false); }
            finally { Clock.Stop(); }
            external.ThrowIfCancellationRequested();
        }
    }

    async Task Worker(CancellationTokenSource cts) {
        var ct = cts.Token;
        try {
            using (var handler = new HttpClientHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None })
            using (var client = new HttpClient(handler)) {
                client.Timeout = Timeout.InfiniteTimeSpan;
                client.DefaultRequestHeaders.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
                byte[] payload = null;
                byte[] buffer = new byte[65536];
                if (!down) { payload = new byte[5000000]; using (var rng = RandomNumberGenerator.Create()) { rng.GetBytes(payload); } }
                int size = down ? 25000000 : 5000000;
                while (!ct.IsCancellationRequested) {
                    long old = Interlocked.Read(ref reserved);
                    if (old + size > cap) break;
                    if (Interlocked.CompareExchange(ref reserved, old + size, old) != old) continue;
                    if (down) {
                        using (var response = await client.GetAsync("https://speed.cloudflare.com/__down?bytes=" + size, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false)) {
                            response.EnsureSuccessStatusCode();
                            using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false)) {
                                long n = 0; int read;
                                while ((read = await stream.ReadAsync(buffer, 0, buffer.Length, ct).ConfigureAwait(false)) > 0) {
                                    n += read;
                                    if (n > size) throw new IOException("Response too large");
                                    Interlocked.Add(ref count, read);
                                }
                                if (n != size) throw new IOException("Incomplete response");
                            }
                        }
                    } else {
                        using (var content = new ByteArrayContent(payload))
                        using (var response = await client.PostAsync("https://speed.cloudflare.com/__up", content, ct).ConfigureAwait(false)) {
                            response.EnsureSuccessStatusCode();
                            Interlocked.Add(ref count, size);
                        }
                    }
                    Interlocked.Increment(ref requests);
                }
            }
        } catch (Exception ex) {
            if (!ct.IsCancellationRequested && Interlocked.CompareExchange(ref failed, 1, 0) == 0) { error = ex.Message; cts.Cancel(); }
        }
    }
}
'@
        Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Net.Http.dll')
    }

    # .NET Framework limits concurrent connections per origin; widen it for this worker only.
    $oldLimit = [Net.ServicePointManager]::DefaultConnectionLimit
    [Net.ServicePointManager]::DefaultConnectionLimit = [math]::Max(4, $oldLimit)
    try {
        foreach ($mode in @('Down', 'Up')) {
            $token.ThrowIfCancellationRequested()
            $down = $mode -eq 'Down'
            $label = if ($down) { 'DOWNLOAD' } else { 'UPLOAD' }
            $cap = if ($down) { 1000000000L } else { 300000000L }
            $base = if ($down) { 15 } else { 57.5 }
            $phase = New-Object BrabusSpeedPhaseV2($down, $cap, $phaseSeconds)
            $task = $phase.Run($token)
            $loaded = @()
            $probe = New-Object Net.NetworkInformation.Ping
            $nextPing = 0.5
            try {
                while (-not $task.IsCompleted) {
                    $token.ThrowIfCancellationRequested()
                    if ($phase.Clock.Elapsed.TotalSeconds -ge $nextPing) {
                        try {
                            $reply = $probe.Send('1.1.1.1', 400)
                            if ($reply.Status -eq 'Success') { $loaded += [double]$reply.RoundtripTime }
                        } catch {
                            Write-Verbose 'Ping sotto carico perso'
                        }
                        $nextPing = $phase.Clock.Elapsed.TotalSeconds + 0.5
                        if ($loaded.Count) { $state[$mode + 'LoadedPing'] = [math]::Round(($loaded | Measure-Object -Average).Average, 1) }
                    }
                    $elapsed = $phase.Clock.Elapsed.TotalSeconds
                    if ($elapsed -gt 0.5 -and $phase.Bytes -gt 0) { $state[$mode] = [math]::Round($phase.Bytes * 8 / 1e6 / $elapsed, 2) }
                    $state.Stage = "$label | $([math]::Round($elapsed, 1)) / $phaseSeconds s"
                    $state.Progress = [math]::Min($base + 42.5, $base + 42.5 * $elapsed / $phaseSeconds)
                    Start-Sleep -Milliseconds 150
                }
                $task.GetAwaiter().GetResult()
            } finally {
                $probe.Dispose()
            }
            $elapsed = $phase.Clock.Elapsed.TotalSeconds
            if ($phase.Bytes -gt 0) { $state[$mode] = [math]::Round($phase.Bytes * 8 / 1e6 / [math]::Max(.001, $elapsed), 2) }
            $state[$mode + 'Bytes'] = $phase.Bytes
            $state[$mode + 'Seconds'] = [math]::Round($elapsed, 2)
            $state[$mode + 'Requests'] = $phase.Requests
            $state[$mode + 'LoadedSamples'] = $loaded.Count
            if ($phase.Limited -and $elapsed -lt ($phaseSeconds - 0.5)) { $state.Limited = $true }
            if ($phase.Error) { $state.Error = $phase.Error; break }
        }
        $state.Elapsed = [math]::Round($total.Elapsed.TotalSeconds, 1)
        $state.Stage = if ($state.Error) { "PARZIALE | server: $($state.Error)" }
        elseif ($state.Limited) { "COMPLETATO | $($state.Elapsed) s | limite dati" }
        elseif (-not $state.Down -or -not $state.Up -or $state.DownSeconds -lt ($phaseSeconds - 1) -or $state.UpSeconds -lt ($phaseSeconds - 1)) { "PARZIALE | $($state.Elapsed) s" }
        else { "COMPLETATO | $($state.Elapsed) s" }
        $state.Progress = 100
    } finally {
        [Net.ServicePointManager]::DefaultConnectionLimit = $oldLimit
    }
}

function Read-SpeedHistory {
    $path = $script:Paths.SpeedHistory
    if (-not (Test-Path -LiteralPath $path)) { return }
    if ((Get-Item -LiteralPath $path).Length -gt 10MB) { throw 'Cronologia troppo grande: conservata senza modifiche' }
    $document = Read-JsonFile -Path $path
    if ($document.Format -ne 'BrabusSpeedHistory' -or $document.Version -ne 1) { throw 'Formato cronologia non valido; file conservato' }
    foreach ($result in @($document.Results)) {
        if ($result) { $result }
    }
}

function Save-SpeedResult {
    <# Keeps the newest 1000 finished (complete or partial) tests; the same TestId is saved once. #>
    param([Parameter(Mandatory)]$State)
    if (-not $State.Stage -or $State.Stage -notmatch '^(COMPLETATO|PARZIALE)' -or $null -eq $State.Elapsed) { return }
    $rows = @(Read-SpeedHistory)
    $id = [string]$State.TestId
    if (-not $id) { $id = [guid]::NewGuid().ToString('N') }
    if ($id -in @($rows | ForEach-Object Id)) { return }
    $complete = $State.Stage -like 'COMPLETATO*' -and -not $State.Limited -and $State.Down -gt 0 -and $State.Up -gt 0
    $result = [pscustomobject]@{
        Id             = $id
        Date           = (Get-Date).ToString('o')
        Method         = if ($State.Method) { $State.Method } else { 'Cloudflare-HTTPS-12s-v1' }
        Status         = if ($complete) { 'Completo' } else { 'Parziale / limite' }
        Down           = $State.Down
        Up             = $State.Up
        Ping           = $State.Ping
        Jitter         = $State.Jitter
        Loss           = $State.Loss
        DownLoadedPing = $State.DownLoadedPing
        UpLoadedPing   = $State.UpLoadedPing
        Seconds        = $State.Elapsed
        DownMB         = [math]::Round([double]$State.DownBytes / 1e6, 1)
        UpMB           = [math]::Round([double]$State.UpBytes / 1e6, 1)
        NetworkConfig  = $State.NetworkConfig
    }
    Save-JsonFile -Path $script:Paths.SpeedHistory -InputObject @{
        Format  = 'BrabusSpeedHistory'
        Version = 1
        Results = @(@($result) + $rows | Select-Object -First 1000)
    }
}

function Get-NetworkRelatedRow {
    <# Browser rows that affect network behavior, shown again in the Network Center. #>
    $keys = @('BackgroundModeEnabled', 'StartupBoostEnabled', 'NetworkPredictionOptions', 'NewTabPagePrerenderEnabled', 'SearchSuggestEnabled', 'AlternateErrorPagesEnabled')
    @($script:Rows | Where-Object { $_.Category -eq 'Browser' -and $_.Key -in $keys })
}

function Get-NetworkFingerprint {
    <#
        Short hash of the network-relevant configuration, to flag speed tests taken under different
        settings. Driver values come from the catalog scan itself: v2.0 re-queried every adapter
        property one by one (seconds of CIM calls) at the start and the end of each test.
    #>
    try {
        $values = @(
            foreach ($row in @(Get-NetworkTweakRow)) { '{0}|{1}|True|String|{2}' -f $row.Path, $row.Key, $row.Before }
            foreach ($row in @(Get-NetworkRelatedRow)) {
                $value = Get-TweakValue -Path $row.Path -Key $row.Key
                '{0}|{1}|{2}|{3}|{4}' -f $row.Path, $row.Key, $value.Exists, $value.Kind, $value.Value
            }
        )
        if (-not $values.Count) { return 'ND' }
        (Get-Sha256Hex (($values | Sort-Object) -join [Environment]::NewLine)).Substring(0, 12)
    } catch {
        'ND'
    }
}

function Get-SpeedComparison {
    <# Text comparing the two newest complete tests of the same method (no causality claimed). #>
    param([object[]]$Rows)
    $latest = @($Rows | Where-Object Status -EQ 'Completo' | Select-Object -First 1)
    if (-not $latest.Count) { return 'Servono due test completi comparabili.' }
    $complete = @($Rows | Where-Object { $_.Status -eq 'Completo' -and $_.Method -eq $latest[0].Method })
    if ($complete.Count -lt 2) { return 'Servono due test completi comparabili.' }
    $a = $complete[0]
    $b = $complete[1]
    $message = 'Ultimo vs precedente completo: download {0:+0.00;-0.00;0.00} Mbps | upload {1:+0.00;-0.00;0.00} Mbps' -f ([double]$a.Down - [double]$b.Down), ([double]$a.Up - [double]$b.Up)
    if ($null -ne $a.Ping -and $null -ne $b.Ping) { $message += (' | ping {0:+0.0;-0.0;0.0} ms' -f ([double]$a.Ping - [double]$b.Ping)) }
    $message += if ($a.NetworkConfig -eq 'ND' -or $b.NetworkConfig -eq 'ND') { ' | configurazione non rilevata' }
    elseif ($a.NetworkConfig -eq $b.NetworkConfig) { ' | configurazione rilevata invariata' }
    else { ' | configurazione rilevata diversa' }
    $message + ' | non dimostra causalita.'
}

#endregion

#region GUI: XAML layout -------------------------------------------------------------------------

function Get-MainWindowXaml {
    <# Main window layout (WPF). Every element with Name= is indexed in $script:Ui at load time. #>
    @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="BRABUS UTIL | ONE-SHOT DEBLOATER" Width="1440" Height="900" MinWidth="970" MinHeight="650" Background="#080D16" Foreground="#DCE9FC" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#101B2A"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E3ECF9"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#17283C"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#E3ECF9"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#174862"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#DCE9FC"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#17283C"/>
      <Setter Property="Foreground" Value="#DCE9FC"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderBrush" Value="#29445F"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#24435B"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#126480"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value=".45"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#5CE1F5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E3ECF9"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="cb" Width="18" Height="18" Background="#0C1726" BorderBrush="#52718A" BorderThickness="1" CornerRadius="3">
                <Path x:Name="tick" Data="M 3,9 L 7,13 L 15,4" Stroke="#071521" StrokeThickness="2.5" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="cb" Property="Background" Value="#43D7E8"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value=".5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#101B2A"/>
      <Setter Property="Foreground" Value="#E3ECF9"/>
      <Setter Property="CaretBrush" Value="#43D7E8"/>
      <Setter Property="SelectionBrush" Value="#24758D"/>
      <Setter Property="BorderBrush" Value="#29445F"/>
      <Setter Property="Padding" Value="9"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="#0E1928"/>
      <Setter Property="BorderBrush" Value="#253B50"/>
      <Setter Property="Padding" Value="6"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#9EB5CC"/>
      <Setter Property="Background" Value="#111F32"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="tab" Background="{TemplateBinding Background}" BorderBrush="#253B50" BorderThickness="1" CornerRadius="5,5,0,0" Padding="{TemplateBinding Padding}" Margin="2,0">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="tab" Property="Background" Value="#173A50"/>
                <Setter Property="Foreground" Value="#5CE1F5"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="tab" Property="BorderBrush" Value="#43D7E8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#0D1725"/>
      <Setter Property="Foreground" Value="#DCE9FC"/>
      <Setter Property="RowBackground" Value="#111F30"/>
      <Setter Property="AlternatingRowBackground" Value="#152539"/>
      <Setter Property="BorderBrush" Value="#253B50"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#24384E"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeight" Value="36"/>
      <Setter Property="ColumnHeaderHeight" Value="39"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#20354A"/>
      <Setter Property="Foreground" Value="#99DDE8"/>
      <Setter Property="BorderBrush" Value="#29445F"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Foreground" Value="#DCE9FC"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#174862"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Foreground" Value="#DCE9FC"/>
      <Setter Property="Padding" Value="6"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#174862"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="#101B2A"/>
      <Setter Property="Foreground" Value="#E3ECF9"/>
      <Setter Property="BorderBrush" Value="#29445F"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#E3ECF9"/>
      <Setter Property="Padding" Value="8"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#174862"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="ScrollPageButton" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Border x:Name="rail" Background="#101C2B" CornerRadius="4" Margin="2,1"/>
              <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" ViewportSize="{TemplateBinding ViewportSize}" Value="{Binding Value,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton x:Name="pageBack" Style="{StaticResource ScrollPageButton}" Command="ScrollBar.PageUpCommand"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb x:Name="grip" Focusable="False">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid Background="Transparent">
                          <Border x:Name="pill" Background="#48627A" CornerRadius="4" Margin="2,1"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="pill" Property="Background" Value="#62B9CD"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="pill" Property="Background" Value="#43D7E8"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton x:Name="pageNext" Style="{StaticResource ScrollPageButton}" Command="ScrollBar.PageDownCommand"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                <Setter TargetName="pageBack" Property="Command" Value="ScrollBar.PageLeftCommand"/>
                <Setter TargetName="pageNext" Property="Command" Value="ScrollBar.PageRightCommand"/>
                <Setter TargetName="rail" Property="Margin" Value="1,2"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="rail" Property="Background" Value="#203348"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="grip" Property="Opacity" Value=".35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="10"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Padding" Value="5,2"/>
      <Setter Property="Margin" Value="1"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="MinHeight" Value="21"/>
    </Style>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Background="#111F32" CornerRadius="12" Padding="10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center">
          <TextBlock Text="CONTROL CENTER  /  2.1 BETA" Foreground="#5CE1F5" FontWeight="Bold"/>
          <TextBlock Text="LOCAL  |  NO AI  |  NO RESIDENT PROCESS" FontSize="11" Foreground="#9EB5CC"/>
        </StackPanel>
        <StackPanel>
          <TextBlock Text="BRABUS / UTIL" FontSize="26" Foreground="#43D7E8" FontWeight="Bold"/>
          <TextBlock Text="ONE-SHOT DEBLOATER  /  SCAN - APPLY - VERIFY - CLOSE" Foreground="#9EB5CC"/>
          <TextBlock Name="Hardware" Foreground="#DCE9FC" TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Grid Grid.Row="1" Margin="0,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition/>
        <ColumnDefinition/>
        <ColumnDefinition/>
        <ColumnDefinition/>
      </Grid.ColumnDefinitions>
      <Border Background="#122236" CornerRadius="8" Padding="8" Margin="0,0,4,0">
        <StackPanel>
          <TextBlock Text="CATALOGO COMPATIBILE" Foreground="#9EB5CC" FontSize="11"/>
          <TextBlock Name="Total" Text="--" FontSize="24" FontWeight="Bold" Foreground="#43D7E8"/>
        </StackPanel>
      </Border>
      <Border Grid.Column="1" Background="#122236" CornerRadius="8" Padding="8" Margin="2,0">
        <StackPanel>
          <TextBlock Text="TWEAK APPLICABILI" Foreground="#9EB5CC" FontSize="11"/>
          <TextBlock Name="Available" Text="--" FontSize="24" FontWeight="Bold" Foreground="#F4C77B"/>
        </StackPanel>
      </Border>
      <Border Grid.Column="2" Background="#122236" CornerRadius="8" Padding="8" Margin="4,0,0,0">
        <StackPanel>
          <TextBlock Text="GIA CONFIGURATI" Foreground="#9EB5CC" FontSize="11"/>
          <TextBlock Name="Done" Text="--" FontSize="24" FontWeight="Bold" Foreground="#73E6AE"/>
        </StackPanel>
      </Border>
      <Border Grid.Column="3" Background="#122236" CornerRadius="8" Padding="8" Margin="4,0,0,0">
        <StackPanel>
          <TextBlock Text="BACKUP UTENTE / ENERGIA" Foreground="#9EB5CC" FontSize="11"/>
          <TextBlock Name="Pending" Text="--" FontSize="24" FontWeight="Bold" Foreground="#A9C9FA"/>
        </StackPanel>
      </Border>
    </Grid>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="336"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="#111F32" CornerRadius="10" Padding="7" Margin="0,0,8,0">
        <ScrollViewer Name="NavScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" PanningMode="VerticalOnly">
          <StackPanel Name="NavStack" Margin="0,0,3,0">
            <TextBlock Text="01 / PRESET" Foreground="#43D7E8" FontWeight="Bold" Margin="4,2,0,4"/>
            <UniformGrid Name="PresetGrid" Columns="2">
              <UniformGrid.Resources>
                <Style TargetType="Button" BasedOn="{StaticResource NavButton}"/>
              </UniformGrid.Resources>
              <Button Name="Scan" Content="ANALIZZA PC"/>
              <Button Name="Safe" Content="SAFE"/>
              <Button Name="Gaming" Content="GAMING"/>
              <Button Name="Ultimate" Content="ULTIMATE"/>
              <Button Name="SelectAll" Content="SELEZIONA TUTTO" Background="#0C7189"/>
              <Button Name="Clear" Content="DESELEZIONA TUTTO"/>
              <Button Name="Export" Content="ESPORTA PROFILO" ToolTip="Esporta i valori attualmente configurati"/>
              <Button Name="Import" Content="IMPORTA PROFILO"/>
            </UniformGrid>
            <TextBlock Text="02 / CATEGORIE TWEAK" Foreground="#43D7E8" FontWeight="Bold" Margin="4,7,0,3"/>
            <ListBox Name="CategoryList" Margin="0" Background="Transparent" BorderThickness="0" ScrollViewer.VerticalScrollBarVisibility="Disabled" ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="False">
              <ListBox.Template>
                <ControlTemplate TargetType="ListBox">
                  <ItemsPresenter/>
                </ControlTemplate>
              </ListBox.Template>
              <ListBox.ItemsPanel>
                <ItemsPanelTemplate>
                  <UniformGrid Columns="3"/>
                </ItemsPanelTemplate>
              </ListBox.ItemsPanel>
              <ListBox.ItemTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding}" TextTrimming="CharacterEllipsis" TextAlignment="Center" ToolTip="{Binding}"/>
                </DataTemplate>
              </ListBox.ItemTemplate>
              <ListBox.ItemContainerStyle>
                <Style TargetType="ListBoxItem">
                  <Setter Property="Margin" Value="1"/>
                  <Setter Property="Padding" Value="3,2"/>
                  <Setter Property="MinHeight" Value="21"/>
                  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  <Setter Property="FontSize" Value="11"/>
                  <Setter Property="Foreground" Value="#DCE9FC"/>
                  <Setter Property="Cursor" Value="Hand"/>
                  <Setter Property="Template">
                    <Setter.Value>
                      <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="cat" Background="#17283C" BorderBrush="#29445F" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
                          <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="cat" Property="Background" Value="#126480"/>
                            <Setter TargetName="cat" Property="BorderBrush" Value="#43D7E8"/>
                          </Trigger>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="cat" Property="BorderBrush" Value="#62B9CD"/>
                          </Trigger>
                          <Trigger Property="IsKeyboardFocused" Value="True">
                            <Setter TargetName="cat" Property="BorderBrush" Value="#5CE1F5"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Setter.Value>
                  </Setter>
                </Style>
              </ListBox.ItemContainerStyle>
            </ListBox>
            <TextBlock Text="03 / STRUMENTI" Foreground="#43D7E8" FontWeight="Bold" Margin="4,7,0,3"/>
            <UniformGrid Name="ToolGrid" Columns="2">
              <UniformGrid.Resources>
                <Style TargetType="Button" BasedOn="{StaticResource NavButton}"/>
              </UniformGrid.Resources>
              <Button Name="Debloat" Content="RIMUOVI APP" ToolTip="Rimuovi app opzionali"/>
              <Button Name="Apps" Content="APP INSTALLATE"/>
              <Button Name="Startup" Content="AVVIO WINDOWS"/>
              <Button Name="Power" Content="ENERGIA / CPU" ToolTip="Piani energetici"/>
              <Button Name="Storage" Content="ARCHIVIAZIONE"/>
              <Button Name="Graphics" Content="GRAFICA WINDOWS"/>
              <Button Name="GpuApp" Content="GPU PER GIOCO"/>
              <Button Name="Software" Content="SOFTWARE CENTER"/>
              <Button Name="Features" Content="FUNZIONALITA WIN" ToolTip="Funzionalita Windows"/>
              <Button Name="Services" Content="SERVIZI WINDOWS"/>
              <Button Name="Diag" Content="DIAGNOSTICA" ToolTip="Diagnostica avanzata"/>
              <Button Name="Updates" Content="WINDOWS UPDATE"/>
              <Button Name="Audio" Content="AUDIO E NOTIFICHE"/>
              <Button Name="Network" Content="NETWORK CENTER" Background="#0C7189"/>
            </UniformGrid>
            <TextBlock Text="04 / RIPRISTINO" Foreground="#43D7E8" FontWeight="Bold" Margin="4,7,0,3"/>
            <UniformGrid Name="RecoveryGrid" Columns="2">
              <UniformGrid.Resources>
                <Style TargetType="Button" BasedOn="{StaticResource NavButton}"/>
              </UniformGrid.Resources>
              <Button Name="Backup" Content="BACKUP / RECOVERY"/>
              <Button Name="Undo" Content="RIPRISTINA TUTTO" ToolTip="Ripristina backup utente, energia e driver; admin per driver"/>
              <Button Name="Files" Content="LOG E REPORT"/>
              <Button Name="Audit" Content="VERIFICA TWEAK" Background="#0C7189"/>
            </UniformGrid>
            <TextBlock Text="Nessuna modifica automatica a Defender o firewall" Foreground="#73E6AE" TextWrapping="Wrap" Margin="4,5,0,2" FontSize="11"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
      <TabControl Grid.Column="1" Name="Tabs">
        <TabItem Header="IMPOSTAZIONI">
          <DockPanel Margin="6">
            <Border DockPanel.Dock="Bottom" Background="#17283C" Padding="12" CornerRadius="6" Margin="0,8,0,0">
              <TextBlock Name="TweakDetail" Text="Seleziona una voce per vedere i dettagli." TextWrapping="Wrap" MinHeight="45"/>
            </Border>
            <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
              <DockPanel>
                <Button DockPanel.Dock="Right" Name="SelectPage" Content="SELEZIONA VISIBILI"/>
                <TextBlock Name="CategoryTitle" Text="IMPOSTAZIONI / Tutte" FontSize="21" FontWeight="Bold" Foreground="#43D7E8" VerticalAlignment="Center"/>
              </DockPanel>
              <TextBlock Text="RICERCA / nome, categoria, stato, descrizione o chiave" Foreground="#9EB5CC" FontSize="11"/>
              <TextBox Name="Filter" Margin="0,4,0,5"/>
              <WrapPanel Margin="0,0,0,3">
                <TextBlock Text="PWU" FontWeight="Bold" Foreground="#43D7E8" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <Button Name="PWUAll" Content="Tutti" Padding="8,4" Margin="2"/>
                <Button Name="PWULow" Content="Low" Padding="8,4" Margin="2"/>
                <Button Name="PWUMedium" Content="Medium" Padding="8,4" Margin="2"/>
                <Button Name="PWUHigh" Content="High" Padding="8,4" Margin="2"/>
                <TextBlock Text="STATO" Foreground="#9EB5CC" VerticalAlignment="Center" Margin="10,0,5,0"/>
                <Button Name="StateAll" Content="Tutti" Padding="8,4" Margin="2"/>
                <Button Name="StateAvailable" Content="Disponibili" Padding="8,4" Margin="2"/>
                <Button Name="StateDone" Content="Configurati" Padding="8,4" Margin="2"/>
                <Button Name="StateSelected" Content="Selezionati" Padding="8,4" Margin="2"/>
                <Button Name="ResetFilters" Content="RESET" Padding="8,4" Margin="2"/>
              </WrapPanel>
              <DockPanel>
                <TextBlock Name="FilterCount" Foreground="#AFC9DF" VerticalAlignment="Center" DockPanel.Dock="Right"/>
                <TextBlock Text="PWU: impatto potenziale, non benchmark. Clicca la colonna per ordinare." Foreground="#9EB5CC" FontSize="11" TextWrapping="Wrap"/>
              </DockPanel>
            </StackPanel>
            <DataGrid Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" SelectionMode="Extended" EnableRowVirtualization="True">
              <DataGrid.Columns>
                <DataGridTemplateColumn Header="ON" Width="46">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsEnabled="{Binding CanSelect,FallbackValue=True}" IsChecked="{Binding Selected,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" ToolTip="{Binding SelectionHint}" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Categoria" Binding="{Binding Category}" IsReadOnly="True" Width="90"/>
                <DataGridTemplateColumn Header="PWU" SortMemberPath="PWURank" CanUserSort="True" IsReadOnly="True" Width="78">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Border CornerRadius="4" Padding="4,2" HorizontalAlignment="Center" VerticalAlignment="Center" ToolTip="{Binding PWUReason}">
                        <Border.Style>
                          <Style TargetType="Border">
                            <Setter Property="Background" Value="#28394C"/>
                            <Style.Triggers>
                              <DataTrigger Binding="{Binding PWU}" Value="Medium">
                                <Setter Property="Background" Value="#78521D"/>
                              </DataTrigger>
                              <DataTrigger Binding="{Binding PWU}" Value="High">
                                <Setter Property="Background" Value="#175A46"/>
                              </DataTrigger>
                            </Style.Triggers>
                          </Style>
                        </Border.Style>
                        <TextBlock Text="{Binding PWU}" FontWeight="SemiBold" FontSize="11" Foreground="#F2F6FC"/>
                      </Border>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Modifica" Binding="{Binding Name}" IsReadOnly="True" Width="2*" MinWidth="155"/>
                <DataGridTextColumn Header="Prima" Binding="{Binding Before}" IsReadOnly="True" Width="85"/>
                <DataGridTextColumn Header="Dopo" Binding="{Binding After}" IsReadOnly="True" Width="85"/>
                <DataGridTextColumn Header="Stato" Binding="{Binding VerifiedStatus}" IsReadOnly="True" Width="175"/>
                <DataGridTextColumn Header="Spiegazione" Binding="{Binding Note}" IsReadOnly="True" Width="3*" MinWidth="115"/>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </TabItem>
        <TabItem Header="REPORT PC">
          <TextBox Name="Report" IsReadOnly="True" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </TabItem>
        <TabItem Header="CHANGE LOG">
          <TextBox Name="History" IsReadOnly="True" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </TabItem>
        <TabItem Header="CONTROL CENTER">
          <DockPanel Margin="8">
            <Border DockPanel.Dock="Top" Background="#14283B" Padding="16" CornerRadius="8" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Name="PageTitle" Text="CONTROL CENTER" FontSize="26" FontWeight="Bold" Foreground="#43D7E8"/>
                <TextBlock Name="PageHint" Text="Apri uno strumento dal menu a sinistra." Foreground="#AFC9DF" TextWrapping="Wrap" Margin="0,6,0,8"/>
                <DockPanel>
                  <Button DockPanel.Dock="Right" Name="PageRefresh" Content="AGGIORNA"/>
                  <TextBlock DockPanel.Dock="Right" Name="PageCount" VerticalAlignment="Center" Margin="10,0"/>
                  <TextBox Name="PageSearch" Margin="0,4,0,4"/>
                </DockPanel>
              </StackPanel>
            </Border>
            <Border DockPanel.Dock="Bottom" Background="#14283B" Padding="12" CornerRadius="8" Margin="0,10,0,0">
              <StackPanel>
                <TextBlock Text="DETTAGLIO SELEZIONE" Foreground="#43D7E8" FontWeight="Bold"/>
                <TextBox Name="PageDetail" IsReadOnly="True" TextWrapping="Wrap" MinHeight="60" MaxHeight="115" VerticalScrollBarVisibility="Auto" Margin="0,5,0,5"/>
                <WrapPanel HorizontalAlignment="Right">
                  <Button Name="PageCategory" Content="APRI IMPOSTAZIONI CORRELATE" Visibility="Collapsed"/>
                  <Button Name="PageAction" Content="" Visibility="Collapsed" Background="#0C7189"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <DataGrid Name="PageGrid" IsReadOnly="True" SelectionMode="Extended" AutoGenerateColumns="False" CanUserAddRows="False" EnableRowVirtualization="True">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Elemento" Binding="{Binding Name}" Width="2*"/>
                <DataGridTextColumn Header="Stato / Valore" Binding="{Binding State}" Width="*"/>
                <DataGridTextColumn Header="Informazioni" Binding="{Binding Detail}" Width="3*"/>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </TabItem>
        <TabItem Header="NETWORK CENTER">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="9">
              <Border CornerRadius="10" Padding="15" Margin="0,0,0,9">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#173C55" Offset="0"/>
                    <GradientStop Color="#102031" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <StackPanel>
                  <DockPanel>
                    <TextBlock DockPanel.Dock="Right" Text="CLOUDFLARE  /  MULTISTREAM V2" FontSize="11" Foreground="#AFC9DF" VerticalAlignment="Center"/>
                    <TextBlock Text="NETWORK / SPEED LAB" FontSize="25" FontWeight="Bold" Foreground="#43D7E8"/>
                  </DockPanel>
                  <TextBlock Name="NetLink" Text="--" Foreground="#73E6AE" Margin="0,5,0,3"/>
                  <TextBlock Name="NetAdmin" FontSize="11" Foreground="#AFC9DF"/>
                  <TextBlock Text="Test avanzato ~30-37 s | 2 flussi HTTPS | limite 1,3 GB. Ping a riposo e sotto carico." TextWrapping="Wrap" Foreground="#AFC9DF" Margin="0,3,0,0"/>
                </StackPanel>
              </Border>
              <UniformGrid Columns="2" Margin="0,0,0,6">
                <Border Background="#12263A" CornerRadius="8" Padding="13" Margin="0,0,4,0">
                  <StackPanel>
                    <TextBlock Text="DOWNLOAD / Mbps" Foreground="#AFC9DF" FontSize="12"/>
                    <TextBlock Name="NetDown" Text="--" FontSize="42" FontWeight="Bold" Foreground="#43D7E8"/>
                    <TextBlock Text="Velocita ricezione HTTPS" FontSize="11"/>
                  </StackPanel>
                </Border>
                <Border Background="#12263A" CornerRadius="8" Padding="13" Margin="4,0,0,0">
                  <StackPanel>
                    <TextBlock Text="UPLOAD / Mbps" Foreground="#AFC9DF" FontSize="12"/>
                    <TextBlock Name="NetUp" Text="--" FontSize="42" FontWeight="Bold" Foreground="#A9C9FA"/>
                    <TextBlock Text="Velocita invio HTTPS" FontSize="11"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
              <UniformGrid Columns="3" Margin="0,0,0,6">
                <Border Background="#12263A" CornerRadius="8" Padding="10" Margin="0,0,3,0">
                  <StackPanel>
                    <TextBlock Text="PING / ms" FontSize="11"/>
                    <TextBlock Name="NetPing" Text="--" FontSize="26" Foreground="#73E6AE" FontWeight="Bold"/>
                  </StackPanel>
                </Border>
                <Border Background="#12263A" CornerRadius="8" Padding="10" Margin="3,0">
                  <StackPanel>
                    <TextBlock Text="JITTER / ms" FontSize="11"/>
                    <TextBlock Name="NetJitter" Text="--" FontSize="26" Foreground="#F4C77B" FontWeight="Bold"/>
                  </StackPanel>
                </Border>
                <Border Background="#12263A" CornerRadius="8" Padding="10" Margin="3,0,0,0">
                  <StackPanel>
                    <TextBlock Text="LOSS / %" FontSize="11"/>
                    <TextBlock Name="NetLoss" Text="--" FontSize="26" Foreground="#A9C9FA" FontWeight="Bold"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
              <UniformGrid Columns="2" Margin="0,0,0,6">
                <Border Background="#12263A" CornerRadius="8" Padding="10" Margin="0,0,4,0">
                  <StackPanel>
                    <TextBlock Text="PING SOTTO DOWNLOAD / ms" Foreground="#AFC9DF" FontSize="11"/>
                    <TextBlock Name="NetDownLoaded" Text="--" FontSize="26" FontWeight="Bold" Foreground="#F4C77B"/>
                    <TextBlock Text="Media ICMP durante il traffico" FontSize="11"/>
                  </StackPanel>
                </Border>
                <Border Background="#12263A" CornerRadius="8" Padding="10" Margin="4,0,0,0">
                  <StackPanel>
                    <TextBlock Text="PING SOTTO UPLOAD / ms" Foreground="#AFC9DF" FontSize="11"/>
                    <TextBlock Name="NetUpLoaded" Text="--" FontSize="26" FontWeight="Bold" Foreground="#F4C77B"/>
                    <TextBlock Text="Media ICMP durante il traffico" FontSize="11"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
              <Border Background="#101B2A" CornerRadius="8" Padding="10" Margin="0,0,0,8">
                <StackPanel>
                  <DockPanel>
                    <TextBlock DockPanel.Dock="Right" Name="NetStage" Text="PRONTO" Foreground="#43D7E8" TextWrapping="Wrap" MaxWidth="240"/>
                    <TextBlock Text="LATENCY TRACE / 10 PING A RIPOSO" FontSize="11" Foreground="#AFC9DF"/>
                  </DockPanel>
                  <Viewbox Stretch="Fill" Height="72">
                    <Canvas Width="300" Height="84">
                      <Path Stroke="#29445F" StrokeThickness="1" Data="M 10,10 L 290,10 M 10,42 L 290,42 M 10,75 L 290,75"/>
                      <Polyline Name="NetTrace" Stroke="#43D7E8" StrokeThickness="2" StrokeLineJoin="Round"/>
                    </Canvas>
                  </Viewbox>
                  <ProgressBar Name="NetProgress" Height="7" Maximum="100" Value="0" Foreground="#43D7E8" Background="#22384D"/>
                  <WrapPanel HorizontalAlignment="Center" Margin="0,5,0,0">
                    <Button Name="NetStart" Content="AVVIA SPEED TEST" Background="#0C7189"/>
                    <Button Name="NetCancel" Content="ANNULLA" IsEnabled="False"/>
                    <Button Name="NetRefresh" Content="AGGIORNA RETE"/>
                    <Button Name="NetHistory" Content="CRONOLOGIA TEST"/>
                    <Button Name="NetFlushDNS" Content="SVUOTA CACHE DNS"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Background="#14283B" CornerRadius="8" Padding="10" Margin="0,0,0,8">
                <StackPanel>
                  <TextBlock Text="DNS ATTUALI / INTERFACCE" FontWeight="Bold" Foreground="#43D7E8"/>
                  <TextBlock Name="NetInfo" Text="--" TextWrapping="Wrap" Margin="0,5,0,0"/>
                </StackPanel>
              </Border>
              <TextBlock Text="NETWORK TWEAKS / DRIVER + BROWSER" FontSize="17" FontWeight="Bold" Foreground="#43D7E8" Margin="0,5,0,4"/>
              <TextBlock Text="Spunta le voci o usa Seleziona tutto. Driver: admin e riavvio manuale; browser: backup originale. Spunta disponibili per applicare; spunta voci con backup per ripristinare. Seleziona tutto sceglie solo i disponibili." TextWrapping="Wrap" Foreground="#AFC9DF"/>
              <DataGrid Name="NetGrid" IsReadOnly="False" SelectionMode="Extended" AutoGenerateColumns="False" CanUserAddRows="False" Height="260" Margin="0,8,0,4">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="ON" Width="42">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <CheckBox IsEnabled="{Binding CanSelect}" IsChecked="{Binding Selected,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" ToolTip="{Binding SelectionHint}" VerticalAlignment="Center"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="Tweak" Binding="{Binding Name}" Width="2*" IsReadOnly="True"/>
                  <DataGridTextColumn Header="PWU" Binding="{Binding PWU}" IsReadOnly="True" Width="65"/>
                  <DataGridTextColumn Header="Prima" Binding="{Binding Before}" IsReadOnly="True" Width="80"/>
                  <DataGridTextColumn Header="Dopo" Binding="{Binding After}" IsReadOnly="True" Width="80"/>
                  <DataGridTextColumn Header="Stato" Binding="{Binding VerifiedStatus}" IsReadOnly="True" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
              <TextBlock Name="NetDetail" Text="Seleziona una voce per dettagli." TextWrapping="Wrap" Foreground="#AFC9DF" Margin="0,3,0,5"/>
              <WrapPanel>
                <Button Name="NetSelectAll" Content="SELEZIONA TUTTO"/>
                <Button Name="NetClear" Content="DESELEZIONA TUTTO"/>
                <Button Name="NetApply" Content="APPLICA SELEZIONATI" Background="#0C7189"/>
                <TextBlock Name="NetSelectedCount" Text="0 selezionati" VerticalAlignment="Center" Margin="6,0"/>
                <Button Name="NetRestore" Content="RIPRISTINA DRIVER" IsEnabled="False"/>
                <TextBlock Name="NetBackupCount" Text="Backup rete: --" VerticalAlignment="Center" Margin="8,0"/>
              </WrapPanel>
            </StackPanel>
          </ScrollViewer>
        </TabItem>
        <TabItem Header="STORICO RETE">
          <DockPanel Margin="9">
            <Border DockPanel.Dock="Top" Background="#14283B" CornerRadius="8" Padding="14" Margin="0,0,0,8">
              <StackPanel>
                <TextBlock Text="SPEED LAB / CRONOLOGIA" FontSize="23" FontWeight="Bold" Foreground="#43D7E8"/>
                <TextBlock Name="SpeedHistoryCount" Text="0 test salvati" Foreground="#AFC9DF" Margin="0,5"/>
                <TextBlock Name="SpeedHistoryCompare" Text="--" TextWrapping="Wrap" Foreground="#73E6AE"/>
                <TextBlock Text="Confronto tra gli ultimi due test completi; la configurazione rilevata non dimostra un miglioramento causato dai tweak. I risultati parziali restano separati." TextWrapping="Wrap" Foreground="#AFC9DF" Margin="0,4"/>
                <WrapPanel>
                  <Button Name="SpeedHistoryBack" Content="TORNA A SPEED LAB"/>
                  <Button Name="SpeedHistoryRefresh" Content="AGGIORNA"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <DataGrid Name="SpeedHistoryGrid" IsReadOnly="True" AutoGenerateColumns="False" CanUserAddRows="False" EnableRowVirtualization="True">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Data / ora" Binding="{Binding LocalDate}" Width="155"/>
                <DataGridTextColumn Header="Down Mbps" Binding="{Binding Down}" Width="90"/>
                <DataGridTextColumn Header="Up Mbps" Binding="{Binding Up}" Width="85"/>
                <DataGridTextColumn Header="Ping ms" Binding="{Binding Ping}" Width="75"/>
                <DataGridTextColumn Header="Jitter ms" Binding="{Binding Jitter}" Width="75"/>
                <DataGridTextColumn Header="Loss %" Binding="{Binding Loss}" Width="65"/>
                <DataGridTextColumn Header="Durata s" Binding="{Binding Seconds}" Width="75"/>
                <DataGridTextColumn Header="Stato" Binding="{Binding Status}" Width="130"/>
                <DataGridTextColumn Header="Ping down ms" Binding="{Binding DownLoadedPing}" Width="95"/>
                <DataGridTextColumn Header="Ping up ms" Binding="{Binding UpLoadedPing}" Width="90"/>
                <DataGridTextColumn Header="Metodo" Binding="{Binding Method}" Width="175"/>
                <DataGridTextColumn Header="Config." Binding="{Binding NetworkConfig}" Width="110"/>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </TabItem>
      </TabControl>
    </Grid>
    <Border Grid.Row="3" Background="#111F32" CornerRadius="8" Padding="6" Margin="0,6,0,0">
      <DockPanel>
        <Button DockPanel.Dock="Right" Name="Apply" Background="#0C7189" Content="APPLICA MODIFICHE SELEZIONATE" FontWeight="Bold" Padding="12,10"/>
        <Button DockPanel.Dock="Right" Name="RestoreSelected" Content="RIPRISTINA SELEZIONATI (0)" FontWeight="Bold" Padding="9,10" IsEnabled="False"/>
        <Button DockPanel.Dock="Right" Name="SelectRestore" Content="SELEZIONA RIPRISTINABILI" Padding="7,10"/>
        <TextBlock Name="Status" Text="Scansione iniziale..." TextWrapping="Wrap" VerticalAlignment="Center" Margin="6"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@
}

#endregion

#region GUI: view state, window and dialogs -------------------------------------------------------

$script:Rows = @()
$script:NetRows = $null
$script:Category = 'Tutte'
$script:PwuFilter = 'All'
$script:StateFilter = 'All'
$script:Page = ''
$script:PageRows = @()
$script:NetJob = $null
$script:NetState = $null
$script:NetTimer = $null
$script:Window = $null
$script:Ui = @{}
$script:IsAdmin = $false
$script:Tab = @{ Settings = 0; Report = 1; ChangeLog = 2; ControlCenter = 3; Network = 4; SpeedHistory = 5 }

function Initialize-MainWindow {
    <# Loads the XAML and indexes every named control in $script:Ui (missing controls fail fast). #>
    Add-Type -AssemblyName PresentationFramework
    if (-not ('BrabusDwm' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BrabusDwm {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
'@
    }
    [xml]$xaml = Get-MainWindowXaml
    $script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $script:Ui = @{}
    foreach ($node in $xaml.SelectNodes('//*[@Name]')) {
        $name = $node.GetAttribute('Name')
        $control = $script:Window.FindName($name)
        if (-not $control) { throw "Controllo GUI mancante: $name" }
        $script:Ui[$name] = $control
    }
    Register-MainWindowHandler
}

function Set-StatusText {
    param([string]$Text)
    $script:Ui.Status.Text = $Text
}

function Invoke-Guarded {
    <# Every UI action runs here: errors become a status message instead of a crash. #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    } catch {
        Set-StatusText ('ERRORE: ' + $_.Exception.Message)
        Update-ChangeLogView
    }
}

function Assert-NoSpeedTest {
    param([string]$Message = 'Attendi la fine dello speed test')
    if ($script:NetJob) { throw $Message }
}

function Set-DarkTitleBar {
    param([Parameter(Mandatory)]$Window)
    try {
        $Window.Add_SourceInitialized({
                try {
                    $handle = (New-Object Windows.Interop.WindowInteropHelper $this).Handle
                    $enabled = 1
                    $null = [BrabusDwm]::DwmSetWindowAttribute($handle, 20, [ref]$enabled, 4)
                } catch {
                    Write-Verbose 'Barra del titolo scura non supportata'
                }
            })
    } catch {
        Write-Verbose 'Barra del titolo scura non supportata'
    }
}

function New-DialogWindow {
    param([string]$Title, [int]$Width, [int]$Height)
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Width = $Width
    $dialog.Height = $Height
    $dialog.Owner = $script:Window
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Background = '#0B1220'
    $dialog.Foreground = '#E3ECF9'
    $dialog.Resources.MergedDictionaries.Add($script:Window.Resources)
    Set-DarkTitleBar -Window $dialog
    $dialog
}

function Show-ConfirmDialog {
    <# Dark modal confirmation with scrollable details. Returns $true only on CONFERMA. #>
    param([string]$Title, [string]$Message)
    $dialog = New-DialogWindow -Title $Title -Width 720 -Height 500
    $panel = New-Object Windows.Controls.DockPanel
    $panel.Margin = '18'
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')
    $yes = New-Object Windows.Controls.Button
    $yes.Content = 'CONFERMA'
    $yes.Background = '#0C7189'
    $no = New-Object Windows.Controls.Button
    $no.Content = 'ANNULLA'
    $no.IsCancel = $true
    $null = $buttons.Children.Add($no)
    $null = $buttons.Children.Add($yes)
    $null = $panel.Children.Add($buttons)
    $text = New-Object Windows.Controls.TextBox
    $text.Text = $Message
    $text.IsReadOnly = $true
    $text.TextWrapping = 'Wrap'
    $text.VerticalScrollBarVisibility = 'Auto'
    $text.Margin = '0,0,0,12'
    $null = $panel.Children.Add($text)
    $dialog.Content = $panel
    $yes.Add_Click({ $dialog.DialogResult = $true })
    $dialog.ShowDialog() -eq $true
}

#endregion

#region GUI: settings grid, filters and dashboard -------------------------------------------------

function Update-Dashboard {
    $total = $script:Rows.Count
    $done = @($script:Rows | Where-Object Status -EQ $script:StatusConfigured).Count
    $available = @($script:Rows | Where-Object { Test-ApplyChoice $_ }).Count
    $blocked = @($script:Rows | Where-Object { $_.Status -eq $script:StatusAvailable -and -not (Test-ApplyChoice $_) }).Count
    $script:Ui.Total.Text = [string]$total
    $script:Ui.Available.Text = [string]$available
    $script:Ui.Available.ToolTip = "$blocked voci non applicabili per backup, conflitto, permessi o errore. Consulta Verifica tweak."
    $script:Ui.Done.Text = "$done / $total"
    try {
        $backup = Get-BackupStatus
        $script:Ui.Pending.Text = [string]$backup.Pending
        if ($backup.Warning) { Set-StatusText $backup.Warning }
    } catch {
        $script:Ui.Pending.Text = 'ERRORE'
        Set-StatusText $_.Exception.Message
    }
}

function Update-FilterButtonState {
    $active = '#126480'
    $idle = '#17283C'
    foreach ($pair in @(@('PWUAll', 'All'), @('PWULow', 'Low'), @('PWUMedium', 'Medium'), @('PWUHigh', 'High'))) {
        $script:Ui[$pair[0]].Background = if ($script:PwuFilter -eq $pair[1]) { $active } else { $idle }
    }
    foreach ($pair in @(@('StateAll', 'All'), @('StateAvailable', 'Available'), @('StateDone', 'Done'), @('StateSelected', 'Selected'))) {
        $script:Ui[$pair[0]].Background = if ($script:StateFilter -eq $pair[1]) { $active } else { $idle }
    }
}

function Update-GridFilter {
    <# Category + PWU + state filters, then every search token must appear somewhere in the row. #>
    $terms = @($script:Ui.Filter.Text.Trim() -split '\s+' | Where-Object { $_ })
    $visible = @($script:Rows | Where-Object {
            $row = $_
            if ($script:Category -and $script:Category -ne 'Tutte' -and $row.Category -ne $script:Category) { return $false }
            if ($script:PwuFilter -ne 'All' -and $row.PWU -ne $script:PwuFilter) { return $false }
            if ($script:StateFilter -eq 'Available' -and $row.Status -ne $script:StatusAvailable) { return $false }
            if ($script:StateFilter -eq 'Done' -and $row.Status -ne $script:StatusConfigured) { return $false }
            if ($script:StateFilter -eq 'Selected' -and -not $row.Selected) { return $false }
            $haystack = "$($row.Name) $($row.Category) $($row.VerifiedStatus) $($row.Status) $($row.Note) $($row.Key) $($row.PWU) $($row.PWUReason)"
            foreach ($term in $terms) {
                if ($haystack.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
            }
            $true
        })
    $script:Ui.Grid.ItemsSource = $visible
    Update-ApplyContext
    $script:Ui.FilterCount.Text = "$($visible.Count) / $($script:Rows.Count) visibili"
}

function Update-ChangeLogView {
    if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.ChangeLog)) {
        $script:Ui.History.Text = (Get-Content -LiteralPath $script:Paths.ChangeLog -Tail 200) -join [Environment]::NewLine
    }
}

function Update-CatalogView {
    <# Rescans the catalog and re-verifies every row; -Preserve keeps still-valid selections. #>
    param([switch]$Preserve)
    $choices = Get-SelectionMap $script:Rows
    Reset-SessionCache
    $script:Rows = @(Get-TweakCatalog)
    Set-VerificationState -Rows $script:Rows
    if ($Preserve) { Restore-SelectionMap -Rows $script:Rows -Map $choices }
    $list = $script:Ui.CategoryList
    $list.ItemsSource = @('Tutte') + @($script:Rows | ForEach-Object Category | Sort-Object -Unique)
    if ($script:Category -notin $list.ItemsSource) { $script:Category = 'Tutte' }
    $list.SelectedItem = $script:Category
    Update-GridFilter
    Update-Dashboard
    Update-ChangeLogView
}

function Get-ActionRow {
    <# Selected rows that can be applied (default) or restored (-Restore), general or network grid. #>
    param([bool]$Network, [bool]$Restore)
    $rows = if ($Network) { $script:NetRows } else { $script:Rows }
    foreach ($row in @($rows)) {
        if (-not $row -or -not $row.Selected) { continue }
        $allowed = if ($Restore) { Test-RestoreChoice $row } else { Test-ApplyChoice $row }
        if ($allowed) { $row }
    }
}

function Select-RestoreChoice {
    param([bool]$Network)
    $rows = if ($Network) { $script:NetRows } else { $script:Rows }
    foreach ($row in @($rows)) { if ($row) { $row.Selected = (Test-RestoreChoice $row) } }
    if ($Network) {
        $script:Ui.NetGrid.Items.Refresh()
        Update-NetworkSelectionCount
    } else {
        $script:Ui.Grid.Items.Refresh()
        Update-GridFilter
        Update-ApplyContext
    }
}

function Select-ApplicableRow {
    <# Selects every applicable row of $Rows that has no active backup; returns the count. #>
    param([object[]]$Rows)
    $pending = @(Read-Journal -Journal $script:UserJournal)
    $count = 0
    foreach ($row in @($Rows)) {
        if ((Test-ApplyChoice $row) -and -not (Find-JournalRecord -Records $pending -Path $row.Path -Key $row.Key)) {
            $row.Selected = $true
            $count++
        }
    }
    $count
}

function Select-Preset {
    <# SAFE = Safe rows; GAMING/ULTIMATE = Safe + Gaming rows. Personal and startup rows stay manual. #>
    param([Parameter(Mandatory)][string]$Preset)
    foreach ($row in $script:Rows) {
        $row.Selected = ((Test-ApplyChoice $row) -and ($row.Level -eq 'Safe' -or ($Preset -ne 'Safe' -and $row.Level -eq 'Gaming')))
    }
    $script:Ui.Grid.Items.Refresh()
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Settings
    # v2.0 never refreshed the footer here: the Apply button stayed disabled after choosing a preset.
    Update-GridFilter
    Set-StatusText "${Preset}: selezionati $(@($script:Rows | Where-Object Selected).Count) tweak conservativi. Le opzioni personali e di avvio restano manuali."
}

function Sync-TweakCheckbox {
    <# Commits a checkbox click to its row immediately (DataGrid would wait for row commit). #>
    param($Source, $EventData)
    $check = $EventData.OriginalSource
    if ($check -isnot [Windows.Controls.CheckBox]) { return }
    $row = $check.DataContext
    if (-not $row -or -not $row.PSObject.Properties['Selected']) { return }
    if ($row.PSObject.Properties['CanSelect'] -and -not $row.CanSelect) {
        $row.Selected = $false
        $check.IsChecked = $false
        return
    }
    $row.Selected = ($check.IsChecked -eq $true)
    $binding = $check.GetBindingExpression([Windows.Controls.Primitives.ToggleButton]::IsCheckedProperty)
    if ($binding) { $binding.UpdateSource() }
    if ($Source.Name -eq 'NetGrid') {
        Update-NetworkSelectionCount
    } else {
        Update-ApplyContext
        if ($script:StateFilter -eq 'Selected') {
            $null = $script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action] { Update-GridFilter })
        }
    }
}

function Update-ApplyContext {
    <# Footer buttons follow the active tab: general settings (0) or Network Center (4). #>
    $tab = $script:Ui.Tabs.SelectedIndex
    $active = $tab -in @($script:Tab.Settings, $script:Tab.Network)
    $network = $tab -eq $script:Tab.Network
    $apply = @(Get-ActionRow -Network $network -Restore $false)
    $undo = @(Get-ActionRow -Network $network -Restore $true)
    $idle = -not $script:NetJob
    $script:Ui.Apply.Content = if ($network) { "APPLICA TWEAK RETE ($($apply.Count))" } else { 'APPLICA MODIFICHE SELEZIONATE' }
    $script:Ui.Apply.IsEnabled = $active -and $idle -and $apply.Count -gt 0
    $script:Ui.Apply.ToolTip = "Applica $($apply.Count) modifiche disponibili; il ripristino e separato."
    $script:Ui.RestoreSelected.Content = "RIPRISTINA SELEZIONATI ($($undo.Count))"
    $script:Ui.RestoreSelected.IsEnabled = $active -and $idle -and $undo.Count -gt 0
    $script:Ui.RestoreSelected.ToolTip = 'Ripristina solo valori originali presenti nel backup; non inverte tweak senza backup.'
    $script:Ui.SelectRestore.IsEnabled = $active -and $idle
    if ($active) {
        $drivers = @(@($apply) + @($undo) | Where-Object { $_.Path -like 'NET|*' }).Count
        $prefix = if ($network) { 'RETE' } else { 'TWEAK' }
        $suffix = if ($drivers -and -not $script:IsAdmin) { ' | driver: amministratore richiesto' } else { '' }
        Set-StatusText ("$prefix : $($apply.Count) da applicare | $($undo.Count) da ripristinare" + $suffix)
    }
}

function Show-BatchResult {
    param([Parameter(Mandatory)]$Result, [string]$Verb)
    $text = "$Verb : $($Result.OK) verificati, $($Result.Failed) errori. Riavvio PC/app se richiesto."
    if ($script:LogWarning) { $text += ' | ' + $script:LogWarning }
    Set-StatusText $text
    if ($Result.Failed) { $null = Show-ConfirmDialog -Title 'Operazioni non riuscite' -Message ($Result.Errors -join [Environment]::NewLine) }
}

function Format-ChangePreview {
    param([object[]]$Rows)
    ($Rows | ForEach-Object { "$($_.Name): $($_.Before) -> $($_.After) | $($_.Note)" }) -join [Environment]::NewLine
}

function Invoke-GeneralApply {
    Assert-NoSpeedTest 'Attendi la fine dello speed test prima di applicare tweak.'
    $grid = $script:Ui.Grid
    $null = $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true)
    $null = $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row, $true)
    $selected = @(Get-ActionRow -Network $false -Restore $false)
    if (-not $selected.Count) { Set-StatusText 'Nessuna modifica selezionata'; return }
    $nl = [Environment]::NewLine
    $preview = 'ATTENZIONE: le opzioni personali possono limitare app, notifiche, funzioni browser e preferenze. Non tutte migliorano gli FPS. Verifica ogni voce prima di confermare.' + $nl + $nl + (Format-ChangePreview $selected)
    if (-not (Show-ConfirmDialog -Title 'Conferma modifiche persistenti' -Message $preview)) { return }
    $result = Invoke-ApplyBatch -Items $selected
    Update-CatalogView -Preserve
    Update-NetworkView -Preserve
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Settings
    Update-ApplyContext
    Show-BatchResult -Result $result -Verb 'Applicazione'
}

function Restore-SelectedTweak {
    Assert-NoSpeedTest
    $network = $script:Ui.Tabs.SelectedIndex -eq $script:Tab.Network
    $items = @(Get-ActionRow -Network $network -Restore $true)
    if (-not $items.Count) { Set-StatusText 'Nessun tweak ripristinabile selezionato'; return }
    if (@($items | Where-Object { $_.Path -like 'NET|*' }).Count -and -not $script:IsAdmin) {
        throw 'Per ripristinare i driver avvia PowerShell come amministratore. Nessuna modifica eseguita.'
    }
    $message = "Ripristinare $($items.Count) valori originali? Nessun riavvio automatico." + [Environment]::NewLine + ($items.Name -join [Environment]::NewLine)
    if (-not (Show-ConfirmDialog -Title 'Ripristino selettivo' -Message $message)) { return }
    $result = Invoke-RestoreBatch -Items $items
    Update-CatalogView -Preserve
    Update-NetworkView -Preserve
    $script:Ui.Tabs.SelectedIndex = if ($network) { $script:Tab.Network } else { $script:Tab.Settings }
    Update-ApplyContext
    Show-BatchResult -Result $result -Verb 'Ripristino'
}

function Restore-EverythingFromUi {
    Assert-NoSpeedTest
    $general = @(Read-Journal -Journal $script:UserJournal)
    $network = @(Read-Journal -Journal $script:NetworkJournal)
    if ($network.Count -and -not $script:IsAdmin) { throw 'Sono presenti backup driver: riapri come amministratore. Nessuna modifica effettuata.' }
    if (-not $general.Count -and -not $network.Count) { Set-StatusText 'Nessun backup attivo'; return }
    $message = "Ripristinare $($general.Count) valori utente/energia e $($network.Count) driver? Le modifiche esterne non verranno sovrascritte. Riavvio manuale se necessario."
    if (-not (Show-ConfirmDialog -Title 'Ripristino completo' -Message $message)) { return }
    $result = Invoke-RestoreBatch -Items (@($general) + @($network))
    Update-CatalogView
    $script:NetRows = $null
    Update-ApplyContext
    Show-BatchResult -Result $result -Verb 'Ripristino completo'
}

#endregion

#region GUI: portable profiles, GPU preference ----------------------------------------------------

function Export-ProfileFromUi {
    Assert-NoSpeedTest
    $document = New-PortableProfile -General @(Get-TweakCatalog) -Network @(Get-NetworkTweakRow)
    if (-not $document.Selections.Count) { throw 'Nessun valore corrispondente agli obiettivi rilevato' }
    $message = "Esportare $($document.Selections.Count) identificatori dei tweak attualmente configurati? Nessun backup, valore originale, percorso personale o identificatore scheda incluso. Il destinatario deve rivedere tutte le preferenze."
    if (-not (Show-ConfirmDialog -Title 'Esporta configurazione attuale' -Message $message)) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Brabus profilo (*.brabus.json)|*.brabus.json'
    $dialog.FileName = 'Brabus-Optimized.brabus.json'
    if ($dialog.ShowDialog($script:Window) -ne $true) { return }
    Save-JsonFile -Path $dialog.FileName -InputObject $document
    Set-StatusText "Profilo esportato: $($document.Selections.Count) identificatori portabili."
}

function Import-ProfileFromUi {
    Assert-NoSpeedTest
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Brabus profilo (*.brabus.json)|*.brabus.json'
    if ($dialog.ShowDialog($script:Window) -ne $true) { return }
    $document = Read-JsonFile -Path $dialog.FileName -MaxBytes 1MB
    Update-CatalogView -Preserve
    Update-NetworkView -Preserve
    $drivers = @($script:NetRows | Where-Object { $_.Path -like 'NET|*' })
    $result = Resolve-PortableProfile -Document $document -General $script:Rows -Network $drivers
    $general = @($result.Eligible | Where-Object { $_.Path -notlike 'NET|*' })
    $network = @($result.Eligible | Where-Object { $_.Path -like 'NET|*' })
    $blocked = [math]::Max(0, $result.Matches.Count - $result.Already - $result.Eligible.Count)
    $nl = [Environment]::NewLine
    $preview = "Compatibili da applicare: $($general.Count) utente/energia + $($network.Count) driver. Gia configurati: $($result.Already). Non compatibili: $($result.Unknown). Ambigui: $($result.Ambiguous). Altri non applicabili: $blocked." +
        $nl + 'Importa soltanto la selezione. Controlla e applica separatamente Impostazioni e Network Center. Nessuna scrittura automatica.' +
        $nl + ($result.Eligible.Name -join $nl)
    if (-not (Show-ConfirmDialog -Title 'Anteprima profilo condiviso' -Message $preview)) { return }
    foreach ($row in $script:Rows) { $row.Selected = ($row -in $general) }
    foreach ($row in $script:NetRows) { $row.Selected = ($row -in $network) }
    $script:Ui.Grid.Items.Refresh()
    $script:Ui.NetGrid.Items.Refresh()
    Show-Category 'Tutte'
    Update-NetworkSelectionCount
    Update-ApplyContext
    Set-StatusText "Importati: $($general.Count) tweak generali e $($network.Count) driver. Nessuna modifica applicata."
}

function Add-GpuPreference {
    <# Per-game "high performance GPU" preference; other fields of the existing value are preserved. #>
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Seleziona eseguibile del gioco'
    $dialog.Filter = 'Applicazioni Windows (*.exe)|*.exe'
    if ($dialog.ShowDialog($script:Window) -ne $true) { return }
    $exe = [IO.Path]::GetFullPath($dialog.FileName)
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Eseguibile non trovato' }
    $path = 'Software\Microsoft\DirectX\UserGpuPreferences'
    $before = Get-TweakValue -Path $path -Key $exe
    if ($before.Exists -and $before.Kind -ne 'String') { throw 'Formato esistente non supportato' }
    $old = if ($before.Exists) { [string]$before.Value } else { '' }
    $fields = @($old.Split(';') | Where-Object { $_ -and $_ -notmatch '^GpuPreference=' })
    $new = ((@($fields) + @('GpuPreference=2')) -join ';') + ';'
    $item = New-TweakRow -Name ('GPU preferita: ' + [IO.Path]::GetFileName($exe)) -Category 'GPU' -Path $path -Key $exe -Before $before `
        -Target (New-ValueState -Exists $true -Kind 'String' -Value $new) -Note 'Preferenza Windows alta prestazione, non overclock; preserva altri campi'
    $nl = [Environment]::NewLine
    $message = "Eseguibile: $exe" + $nl + "Prima: $($item.Before)" + $nl + "Dopo: $($item.After)" + $nl + 'Utile soprattutto con piu GPU; non forza FPS superiori. Riavvia il gioco dopo il cambio.'
    if (-not (Show-ConfirmDialog -Title 'Preferenza GPU per gioco' -Message $message)) { return }
    Set-Tweak -Item $item
    Update-CatalogView
    Set-StatusText 'Preferenza GPU scritta e verificata; ripristinabile. Riavvia il gioco.'
}

#endregion

#region GUI: integrated Control Center pages ------------------------------------------------------

function Show-Category {
    param([string]$Name)
    $script:Category = $Name
    $script:Ui.CategoryTitle.Text = "IMPOSTAZIONI / $Name"
    $list = $script:Ui.CategoryList
    if ($list.SelectedItem -ne $Name -and $Name -in $list.ItemsSource) { $list.SelectedItem = $Name }
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Settings
    Update-GridFilter
}

function Update-PageFilter {
    $query = $script:Ui.PageSearch.Text.Trim()
    $script:Ui.PageGrid.ItemsSource = @($script:PageRows | Where-Object {
            -not $query -or $_.Name -like "*$query*" -or $_.State -like "*$query*" -or $_.Detail -like "*$query*"
        })
}

function Show-Page {
    param([string]$Id, [string]$Title, [string]$Hint, [object[]]$Rows, [string]$Action = '', [string]$Category = '')
    $script:Page = $Id
    $script:PageRows = @($Rows | Where-Object { $_ })
    $script:Ui.PageTitle.Text = $Title
    $script:Ui.PageHint.Text = $Hint
    $script:Ui.PageSearch.Text = ''
    $script:Ui.PageCount.Text = "$($script:PageRows.Count) elementi"
    $script:Ui.PageAction.Content = $Action
    $script:Ui.PageAction.Visibility = if ($Action) { 'Visible' } else { 'Collapsed' }
    $script:Ui.PageCategory.Visibility = if ($Category) { 'Visible' } else { 'Collapsed' }
    $script:Ui.PageCategory.Tag = $Category
    $script:Ui.PageDetail.Text = 'Seleziona una riga per consultare i dettagli.'
    $script:Ui.Tabs.SelectedIndex = $script:Tab.ControlCenter
    Update-PageFilter
}

function Get-PowerPlanRow {
    $active = ''
    try { $active = Get-ActivePowerScheme } catch { $active = '' }
    foreach ($line in ((Invoke-NativeCommand -FilePath 'powercfg.exe' -ArgumentList '/list' -AllowFailure).Output -split '\r?\n')) {
        if ($line -match '([a-fA-F0-9-]{36})\s+\((.*?)\)') {
            New-PageRow -Name $Matches[2] -State $(if ($Matches[1] -eq $active) { 'Attivo' } else { 'Disponibile' }) -Detail $Matches[1]
        }
    }
}

function Get-DiagnosticRow {
    $data = Get-ExtendedDiagnostic
    foreach ($key in $data.Keys) {
        foreach ($value in @($data[$key])) {
            $detail = if ($value -is [string]) { $value } else { (($value | Format-List | Out-String).Trim() -replace '\r?\n', ' | ') }
            New-PageRow -Name $key -State '' -Detail $detail
        }
    }
}

function Get-ToolPageDefinition {
    <#
        Control Center pages: title, hint, rows (scriptblock, evaluated on open), optional action
        button and related settings category. Every page is read-only until its action is confirmed.
    #>
    @{
        Apps     = @{
            Title = 'APP INSTALLATE'
            Hint  = 'Inventario locale Win32 e Microsoft Store; nessuna disinstallazione automatica.'
            Rows  = { Get-InstalledAppRow | Sort-Object Name }
        }
        Debloat  = @{
            Title  = 'DEBLOAT / APP OPZIONALI'
            Hint   = 'Selezione multipla. Rimuove solo app consentite per utente corrente; dati e reinstallazione non garantiti.'
            Rows   = { Get-OptionalPackage | ForEach-Object { New-PageRow -Name $_.Name -State 'Installata' -Detail "Versione: $($_.Version)" -Id $_.PackageFullName } }
            Action = 'RIMUOVI SELEZIONATE'
        }
        Startup  = @{
            Title    = 'AVVIO WINDOWS'
            Hint     = 'Inventario avvio automatico. Le voci modificabili e ripristinabili sono nella categoria Startup.'
            Rows     = { Get-CimInstance Win32_StartupCommand | ForEach-Object { New-PageRow -Name $_.Name -State $_.Location -Detail $_.Command } }
            Category = 'Startup'
        }
        Power    = @{
            Title    = 'ENERGIA / CPU'
            Hint     = 'Piani rilevati. Modifica i parametri compatibili del piano attivo nella categoria Power / CPU. Non cambia piano automaticamente.'
            Rows     = { Get-PowerPlanRow }
            Category = 'Power / CPU'
        }
        Storage  = @{
            Title = 'ARCHIVIAZIONE'
            Hint  = 'Spazio disponibile e salute dei dischi. Nessuna cancellazione automatica.'
            Rows  = {
                Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
                    New-PageRow -Name $_.DeviceID -State ('{0:N1} GB liberi' -f ($_.FreeSpace / 1GB)) -Detail ('Capacita {0:N1} GB | {1:N1}% libero' -f ($_.Size / 1GB), (100 * $_.FreeSpace / [math]::Max([double]1, [double]$_.Size)))
                }
                Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
                    New-PageRow -Name $_.FriendlyName -State $_.HealthStatus -Detail ('{0} | {1:N1} GB | {2}' -f $_.MediaType, ($_.Size / 1GB), $_.OperationalStatus)
                }
            }
        }
        Graphics = @{
            Title    = 'GRAFICA / DISPLAY'
            Hint     = 'GPU, driver e refresh rilevati. Preferenze visive nella categoria Visual; GPU per gioco nella pagina dedicata.'
            Rows     = { Get-CimInstance Win32_VideoController | ForEach-Object { New-PageRow -Name $_.Name -State $_.DriverVersion -Detail "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) | $($_.CurrentRefreshRate) Hz" } }
            Category = 'Visual'
        }
        GpuApp   = @{
            Title  = 'GPU PER GIOCO'
            Hint   = 'Profili GPU Windows per eseguibile. Aggiungi un gioco scegliendo il file EXE; modifica verificata con backup.'
            Rows   = { Get-GpuPreferenceRow }
            Action = 'AGGIUNGI GIOCO'
        }
        Software = @{
            Title  = 'SOFTWARE CENTER'
            Hint   = 'Pacchetti candidati WinGet: verifica ID e dettagli prima di confermare ogni installazione. Gli installer possono aprire una finestra propria.'
            Rows   = { Get-SoftwareCatalog | ForEach-Object { New-PageRow -Name $_.Name -State $_.Category -Detail $_.Id -Id $_.Id } }
            Action = 'VERIFICA E INSTALLA'
        }
        Features = @{
            Title = 'FUNZIONALITA WINDOWS'
            Hint  = 'Inventario funzionalita Windows, in sola lettura per preservare dipendenze di giochi, WSL e virtualizzazione.'
            Rows  = { Get-FeatureInventory | ForEach-Object { New-PageRow -Name $_.Name -State $_.State -Detail 'Funzionalita Windows' } }
        }
        Services = @{
            Title = 'SERVIZI WINDOWS'
            Hint  = 'Stato e tipo avvio. Sola lettura: nessuna disattivazione di servizi o protezioni.'
            Rows  = { Get-ServiceInventory | ForEach-Object { New-PageRow -Name $_.Name -State $_.State -Detail "$($_.StartMode) | $($_.Label)" } }
        }
        Updates  = @{
            Title = 'WINDOWS UPDATE'
            Hint  = 'Stato dei servizi e aggiornamenti installati. Non disattiva aggiornamenti, non installa patch automaticamente.'
            Rows  = {
                Get-Service wuauserv, BITS, DoSvc -ErrorAction SilentlyContinue | ForEach-Object { New-PageRow -Name $_.DisplayName -State $_.Status -Detail $_.StartType }
                Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | ForEach-Object { New-PageRow -Name $_.HotFixID -State $_.Description -Detail $_.InstalledOn }
            }
        }
        Audio    = @{
            Title    = 'AUDIO E NOTIFICHE'
            Hint     = 'Dispositivi audio rilevati; impostazioni notifiche gestite nella categoria Notifications.'
            Rows     = { Get-CimInstance Win32_SoundDevice | ForEach-Object { New-PageRow -Name $_.Name -State $_.Status -Detail $_.Manufacturer } }
            Category = 'Notifications'
        }
        Network  = @{
            Title = 'RETE / DNS'
            Hint  = 'Interfacce, link e DNS correnti. Non altera la rete; dati locali.'
            Rows  = {
                Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { New-PageRow -Name $_.Name -State $_.Status -Detail "$($_.LinkSpeed) | $($_.InterfaceDescription)" }
                Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | ForEach-Object { New-PageRow -Name $_.InterfaceAlias -State 'DNS' -Detail ($_.ServerAddresses -join ', ') }
            }
        }
        Audit    = @{
            Title = 'INTEGRITY / VERIFICA TWEAK'
            Hint  = 'Rilettura dei backup attivi: valore verificato non equivale a guadagno FPS. Nessuna scrittura.'
            Rows  = { Get-ReleaseAudit }
        }
        Diag     = @{
            Title  = 'DIAGNOSTICA AVANZATA'
            Hint   = 'Snapshot hardware e sistema. Nessuna conclusione automatica su colli di bottiglia o latenza.'
            Rows   = { Get-DiagnosticRow }
            Action = 'ESPORTA REPORT'
        }
        Backup   = @{
            Title  = 'BACKUP / RECOVERY'
            Hint   = { $backup = Get-BackupStatus; "$($backup.Pending) modifiche da ripristinare | $($backup.Snapshots) snapshot. $($backup.Warning)" }
            Rows   = { Read-Journal -Journal $script:UserJournal | ForEach-Object { New-PageRow -Name $_.Name -State (Format-State $_.Target) -Detail "Ripristino: $(Format-State $_.Old) | $($_.Time)" -Id $_.Id } }
            Action = 'RIPRISTINA SELEZIONATI'
        }
        Files    = @{
            Title  = 'LOG E REPORT LOCALI'
            Hint   = 'File locali del programma. Seleziona un report o log per visualizzarlo qui; non condividerlo se contiene informazioni personali.'
            Rows   = {
                Get-ChildItem -LiteralPath $script:Paths.Root -File | Where-Object { $_.Name -match '^(scan-|extended-|changes\.jsonl$)' } |
                    Sort-Object LastWriteTime -Descending |
                    ForEach-Object { New-PageRow -Name $_.Name -State $_.LastWriteTime -Detail ('{0:N1} KB' -f ($_.Length / 1KB)) -Id $_.FullName }
            }
            Action = 'LEGGI FILE'
        }
    }
}

function Get-GpuPreferenceRow {
    $handle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\DirectX\UserGpuPreferences')
    if (-not $handle) { return }
    try {
        foreach ($name in $handle.GetValueNames()) {
            New-PageRow -Name ([IO.Path]::GetFileName($name)) -State $handle.GetValue($name) -Detail $name -Id $name
        }
    } finally {
        $handle.Dispose()
    }
}

function Open-ToolPage {
    param([Parameter(Mandatory)][string]$Id)
    $pages = Get-ToolPageDefinition
    if (-not $pages.ContainsKey($Id)) { throw "Pagina non valida: $Id" }
    $page = $pages[$Id]
    $hint = if ($page.Hint -is [scriptblock]) { & $page.Hint } else { $page.Hint }
    Show-Page -Id $Id -Title $page.Title -Hint $hint -Rows @(& $page.Rows) -Action ([string]$page.Action) -Category ([string]$page.Category)
}

function Install-SoftwareFromPage {
    param([Parameter(Mandatory)]$Row)
    $id = $Row.Id
    if (-not (Test-SoftwareId $id)) { throw 'ID non autorizzato' }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'WinGet non disponibile: installa App Installer da Microsoft Store' }
    $details = Invoke-NativeCommand -FilePath $winget.Source -ArgumentList @('show', '--id', $id, '--exact', '--source', 'winget', '--disable-interactivity') -AllowFailure
    if ($details.ExitCode -ne 0) { throw "Pacchetto non verificato: $id" }
    if (-not (Show-ConfirmDialog -Title "Installare $($Row.Name)?" -Message $details.Output)) { return }
    $process = Start-Process -FilePath $winget.Source -ArgumentList @('install', '--id', $id, '--exact', '--source', 'winget', '--interactive') -PassThru -Wait
    Write-ChangeLog -Action "WinGet: $id" -Before 'Installazione' -After $process.ExitCode -Status 'COMANDO TERMINATO'
    Update-ChangeLogView
    Set-StatusText "WinGet exit code: $($process.ExitCode)"
}

function Remove-OptionalAppFromPage {
    param([object[]]$Rows)
    if (-not $Rows.Count) { return }
    $message = 'Dati e preferenze possono andare persi. Ripristino non automatico.' + [Environment]::NewLine + ($Rows.Name -join [Environment]::NewLine)
    if (-not (Show-ConfirmDialog -Title 'Disinstallazione app' -Message $message)) { return }
    $ok = 0
    $failed = 0
    foreach ($row in $Rows) {
        try {
            # Re-check against the allow list at action time: never trust the row alone.
            $app = Get-OptionalPackage | Where-Object PackageFullName -EQ $row.Id | Select-Object -First 1
            if (-not $app) { throw 'App non consentita o non presente' }
            Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
            if (Get-AppxPackage -Name $app.Name) { throw 'App ancora presente' }
            Write-ChangeLog -Action $app.Name -Before 'Installata' -After 'Rimossa' -Status 'VERIFICATO'
            $ok++
        } catch {
            Write-ChangeLog -Action $row.Name -Before 'Installata' -After '?' -Status $_.Exception.Message
            $failed++
        }
    }
    Open-ToolPage 'Debloat'
    Update-ChangeLogView
    Set-StatusText "Rimosse: $ok; errori: $failed"
}

function Invoke-PageAction {
    if ($script:Page -in @('GpuApp', 'Software', 'Debloat', 'Backup')) { Assert-NoSpeedTest }
    $grid = $script:Ui.PageGrid
    $selected = @($grid.SelectedItems)
    $one = $grid.SelectedItem
    switch ($script:Page) {
        'GpuApp' { Add-GpuPreference; Open-ToolPage 'GpuApp' }
        'Software' { if ($one) { Install-SoftwareFromPage -Row $one } }
        'Debloat' { Remove-OptionalAppFromPage -Rows $selected }
        'Backup' {
            if (-not $selected.Count) { return }
            if (Show-ConfirmDialog -Title 'Ripristino selettivo' -Message "Ripristinare $($selected.Count) impostazioni?") {
                Restore-JournalRecordStrict -Journal $script:UserJournal -Id @($selected | ForEach-Object Id)
                Update-CatalogView
                $script:NetRows = $null
                Open-ToolPage 'Backup'
            }
        }
        'Audit' { Open-ToolPage 'Audit' }
        'Diag' { Set-StatusText "Report locale: $(Save-ExtendedDiagnostic)" }
        'Files' {
            if (-not $one) { return }
            $file = Get-Item -LiteralPath $one.Id
            if ($file.DirectoryName -ne $script:Paths.Root -or $file.Length -gt 5MB) { throw 'File non consentito o troppo grande' }
            $script:Ui.Report.Text = [IO.File]::ReadAllText($file.FullName)
            $script:Ui.Tabs.SelectedIndex = $script:Tab.Report
        }
    }
}

#endregion

#region GUI: Network Center -----------------------------------------------------------------------

function Update-NetworkView {
    <# Link, DNS and counters, then driver + browser rows with backup-aware flags. #>
    param([switch]$Preserve)
    $choices = Get-SelectionMap $script:NetRows
    $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -EQ 'Up')
    $script:Ui.NetLink.Text = if ($up.Count) { ($up | ForEach-Object { "$($_.Name) | $($_.LinkSpeed)" }) -join '  /  ' } else { 'Nessuna interfaccia attiva' }
    $indexes = @($up | ForEach-Object ifIndex)
    $names = @($up | ForEach-Object Name)
    $info = @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses -and $_.InterfaceIndex -in $indexes } |
            ForEach-Object { "$($_.InterfaceAlias) DNS: " + ($_.ServerAddresses -join ', ') })
    $info += @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $names } | ForEach-Object {
            "$($_.Name) | Errori RX/TX: $($_.ReceivedPacketErrors)/$($_.OutboundPacketErrors) | Scarti RX/TX: $($_.ReceivedDiscardedPackets)/$($_.OutboundDiscardedPackets)"
        })
    $tcp = Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue
    if ($tcp) { $info += "TCP autotuning: $($tcp.AutoTuningLevelLocal) | Congestione: $($tcp.CongestionProvider)" }
    $script:Ui.NetInfo.Text = $info -join [Environment]::NewLine

    $boot = $null
    try { $boot = (Get-SystemContext).LastBoot } catch { $boot = $null }
    $rows = @(foreach ($item in @(Get-NetworkTweakRow) + @(Get-NetworkRelatedRow)) {
            if (-not $item) { continue }
            $row = $item.PSObject.Copy()
            $row | Add-Member -NotePropertyName Selected -NotePropertyValue $false -Force
            $row
        })
    Set-VerificationState -Rows $rows -Boot $boot
    $script:NetRows = $rows
    if ($Preserve) { Restore-SelectionMap -Rows $script:NetRows -Map $choices }
    $script:Ui.NetGrid.ItemsSource = $script:NetRows
    Update-NetworkSelectionCount
    try {
        $count = @(Read-Journal -Journal $script:NetworkJournal).Count
        $script:Ui.NetBackupCount.Text = "Backup rete: $count"
        $script:Ui.NetRestore.IsEnabled = $count -gt 0
    } catch {
        $script:Ui.NetBackupCount.Text = 'BACKUP RETE: ERRORE'
        $script:Ui.NetRestore.IsEnabled = $false
    }
    $script:Ui.NetAdmin.Text = if ($script:IsAdmin) { 'ADMIN | modifiche driver consentite' } else { 'UTENTE | test e tweak browser; driver richiede admin' }
}

function Update-NetworkSelectionCount {
    $count = @($script:NetRows | Where-Object { $_ -and $_.Selected -and $_.CanSelect }).Count
    $script:Ui.NetSelectedCount.Text = "$count selezionati"
    Update-ApplyContext
}

function Select-NetworkRow {
    param([bool]$Value)
    foreach ($row in @($script:NetRows)) { if ($row) { $row.Selected = ($Value -and (Test-ApplyChoice $row)) } }
    $script:Ui.NetGrid.Items.Refresh()
    Update-NetworkSelectionCount
}

function Invoke-NetworkApply {
    Assert-NoSpeedTest 'Attendi la fine dello speed test prima di applicare tweak.'
    $grid = $script:Ui.NetGrid
    $null = $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true)
    $null = $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row, $true)
    $selected = @(Get-ActionRow -Network $true -Restore $false)
    if (-not $selected.Count) { Set-StatusText 'Nessun tweak rete disponibile selezionato'; return }
    if (@($selected | Where-Object { $_.Path.StartsWith('NET|') }).Count -and -not $script:IsAdmin) {
        throw 'Selezione contiene tweak driver: riapri PowerShell come amministratore, oppure deseleziona i driver. Nessuna modifica applicata.'
    }
    $nl = [Environment]::NewLine
    $preview = "Modifiche selezionate: $($selected.Count)" + $nl + 'Backup prima della scrittura. Nessun riavvio automatico. Possibili variazioni di latenza, throughput e consumi; benefici non garantiti.' + $nl + $nl + (Format-ChangePreview $selected)
    if (-not (Show-ConfirmDialog -Title 'Conferma tweak Internet' -Message $preview)) { return }
    $result = Invoke-ApplyBatch -Items $selected
    Update-CatalogView -Preserve
    Update-NetworkView -Preserve
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Network
    Update-ApplyContext
    Show-BatchResult -Result $result -Verb 'Applicazione rete'
}

function Restore-NetworkDriver {
    Assert-NoSpeedTest 'Attendi la fine dello speed test prima di ripristinare.'
    if (-not $script:IsAdmin) { throw 'Ripristino driver: avvia PowerShell come amministratore' }
    $records = @(Read-Journal -Journal $script:NetworkJournal)
    if (-not $records.Count) { return }
    if (-not (Show-ConfirmDialog -Title 'Ripristino rete' -Message "Ripristinare tutte le $($records.Count) modifiche driver gestite? Nessun riavvio automatico.")) { return }
    Restore-JournalRecordStrict -Journal $script:NetworkJournal -Id @($records | ForEach-Object Id)
    Update-NetworkView
    Set-StatusText 'Ripristino rete verificato; riavvio manuale necessario.'
}

function Show-NetworkTestState {
    param([Parameter(Mandatory)]$State)
    $fields = @(@('NetDown', 'Down'), @('NetUp', 'Up'), @('NetPing', 'Ping'), @('NetJitter', 'Jitter'), @('NetLoss', 'Loss'), @('NetDownLoaded', 'DownLoadedPing'), @('NetUpLoaded', 'UpLoadedPing'))
    foreach ($pair in $fields) {
        $value = $State[$pair[1]]
        $script:Ui[$pair[0]].Text = if ($null -ne $value) { [string]$value } else { '--' }
    }
    $script:Ui.NetProgress.Value = [double]$State.Progress
    $script:Ui.NetStage.Text = [string]$State.Stage
    $points = New-Object Windows.Media.PointCollection
    $samples = @($State.Samples)
    if ($samples.Count -gt 0) {
        $max = [math]::Max([double]1, [double]($samples | Measure-Object -Maximum).Maximum)
        for ($i = 0; $i -lt $samples.Count; $i++) {
            $points.Add((New-Object Windows.Point((10 + 280 * $i / [math]::Max(1, $samples.Count - 1)), (75 - 65 * $samples[$i] / $max))))
        }
    }
    $script:Ui.NetTrace.Points = $points
}

function Update-SpeedHistoryView {
    $rows = @(Read-SpeedHistory)
    $script:Ui.SpeedHistoryGrid.ItemsSource = @($rows | ForEach-Object {
            $row = $_.PSObject.Copy()
            $local = ([datetimeoffset](ConvertTo-UtcTime $_.Date)).LocalDateTime.ToString('dd/MM/yyyy HH:mm:ss')
            $row | Add-Member -NotePropertyName LocalDate -NotePropertyValue $local -Force
            $row
        })
    $script:Ui.SpeedHistoryCount.Text = "$($rows.Count) test salvati | ultimi 1000"
    $script:Ui.SpeedHistoryCompare.Text = Get-SpeedComparison -Rows $rows
}

function Close-NetworkTestJob {
    if ($script:NetJob) {
        $script:NetJob.PS.Dispose()
        if ($script:NetState.CancelSource) { $script:NetState.CancelSource.Dispose() }
        $script:NetJob = $null
    }
    if ($script:NetTimer) { $script:NetTimer.Stop() }
    $script:Ui.NetStart.IsEnabled = $true
    $script:Ui.NetCancel.IsEnabled = $false
    Update-ApplyContext
}

function Stop-NetworkTest {
    if ($script:NetJob) {
        try {
            $script:NetState.CancelSource.Cancel()
            $script:NetJob.PS.Stop()
        } catch {
            Write-Verbose 'Speed test gia terminato'
        }
    }
    Close-NetworkTestJob
}

function Start-NetworkTest {
    if ($script:NetJob) { return }
    $message = 'Test avanzato Cloudflare: circa 30-37 secondi; due flussi paralleli, 14 secondi per direzione, ping a riposo e sotto carico. Fino a 1 GB download + 300 MB upload e overhead; limite dati o errori possono abbreviare il test. Il servizio vede IP e richieste. Evita su connessioni a consumo. Avviare?'
    if (-not (Show-ConfirmDialog -Title 'Speed test Internet' -Message $message)) { return }
    $script:NetState = [hashtable]::Synchronized(@{
            CancelSource = New-Object Threading.CancellationTokenSource; Stage = 'AVVIO'; TestId = [guid]::NewGuid().ToString('N')
            NetworkConfig = Get-NetworkFingerprint; Progress = 0; Samples = @(); Down = $null; Up = $null; Ping = $null; Jitter = $null; Loss = $null
        })
    Show-NetworkTestState $script:NetState
    $shell = [powershell]::Create()
    $null = $shell.AddScript((Get-Command Measure-Connection).ScriptBlock.ToString()).AddArgument($script:NetState)
    $script:NetJob = @{ PS = $shell; Async = $shell.BeginInvoke() }
    $script:Ui.NetStart.IsEnabled = $false
    $script:Ui.NetCancel.IsEnabled = $true
    $script:NetTimer.Start()
    Update-ApplyContext
}

function Update-NetworkTestTick {
    <# Dispatcher timer: renders progress; when the worker ends, saves the result once. #>
    if (-not $script:NetJob) { return }
    Show-NetworkTestState $script:NetState
    if (-not $script:NetJob.Async.IsCompleted) { return }
    try {
        $null = $script:NetJob.PS.EndInvoke($script:NetJob.Async)
        if ($script:NetJob.PS.HadErrors) { throw ($script:NetJob.PS.Streams.Error | Out-String) }
        Show-NetworkTestState $script:NetState
        try {
            if ($script:NetState.NetworkConfig -ne (Get-NetworkFingerprint)) {
                $script:NetState.NetworkConfig = 'ND'
                $script:NetState.Stage = 'PARZIALE | configurazione cambiata durante il test'
            }
            Save-SpeedResult -State $script:NetState
            Update-SpeedHistoryView
        } catch {
            Set-StatusText "Cronologia non salvata: $($_.Exception.Message)"
        }
    } catch {
        $script:Ui.NetStage.Text = if ($script:NetState.Stage -eq 'ANNULLAMENTO') { 'ANNULLATO' } else { "ERRORE: $($_.Exception.Message)" }
    }
    Close-NetworkTestJob
}

#endregion

#region GUI: event wiring -------------------------------------------------------------------------
# Handlers must only use $script: state and their own parameters: locals of this function are gone
# when the events fire. Buttons that share a handler carry their identity in .Tag.

function Invoke-PresetButton {
    param([Parameter(Mandatory)]$Button)
    $preset = [string]$Button.Tag
    Invoke-Guarded { Select-Preset -Preset $preset }
}

function Invoke-PageButton {
    param([Parameter(Mandatory)]$Button)
    $page = [string]$Button.Tag
    Invoke-Guarded { Open-ToolPage -Id $page }
}

function Register-MainWindowHandler {
    $ui = $script:Ui
    $click = [Windows.Controls.Primitives.ButtonBase]::ClickEvent

    # Settings grid, filters and presets
    $ui.Filter.Add_TextChanged({ Update-GridFilter })
    $ui.Grid.AddHandler($click, [Windows.RoutedEventHandler] { param($control, $routed) Sync-TweakCheckbox -Source $control -EventData $routed }, $true)
    $ui.Grid.Add_SelectionChanged({
            $row = $script:Ui.Grid.SelectedItem
            if ($row) {
                $nl = [Environment]::NewLine
                $script:Ui.TweakDetail.Text = "$($row.Name) | $($row.VerifiedStatus) | $($row.Before) -> $($row.After)" + $nl + $row.Note + $nl + "PWU $($row.PWU): $($row.PWUReason)"
            }
        })
    $ui.CategoryList.Add_SelectionChanged({
            $category = $script:Ui.CategoryList.SelectedItem
            if ($category) { Show-Category ([string]$category) }
        })
    foreach ($id in @('PWUAll', 'PWULow', 'PWUMedium', 'PWUHigh')) {
        $ui[$id].Tag = $id.Substring(3)
        $ui[$id].Add_Click({ param($control) $script:PwuFilter = [string]$control.Tag; Update-FilterButtonState; Update-GridFilter })
    }
    foreach ($id in @('StateAll', 'StateAvailable', 'StateDone', 'StateSelected')) {
        $ui[$id].Tag = $id.Substring(5)
        $ui[$id].Add_Click({ param($control) $script:StateFilter = [string]$control.Tag; Update-FilterButtonState; Update-GridFilter })
    }
    $ui.ResetFilters.Add_Click({
            $script:PwuFilter = 'All'
            $script:StateFilter = 'All'
            $script:Ui.Filter.Text = ''
            Show-Category 'Tutte'
            Update-FilterButtonState
            Update-GridFilter
        })
    foreach ($id in @('Safe', 'Gaming', 'Ultimate')) {
        $ui[$id].Tag = $id
        $ui[$id].Add_Click({ param($control) Invoke-PresetButton -Button $control })
    }
    $ui.SelectPage.Add_Click({
            Invoke-Guarded {
                $count = Select-ApplicableRow -Rows @($script:Ui.Grid.ItemsSource)
                $script:Ui.Grid.Items.Refresh()
                if ($script:StateFilter -eq 'Selected') { Update-GridFilter }
                Update-ApplyContext
                Set-StatusText "Selezionate $count voci visibili. Nessuna modifica applicata."
            }
        })
    $ui.SelectAll.Add_Click({
            Invoke-Guarded {
                if ($script:Ui.Tabs.SelectedIndex -eq $script:Tab.Network) { Select-NetworkRow -Value $true; return }
                $null = $script:Ui.Grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true)
                foreach ($row in $script:Rows) { $row.Selected = $false }
                $count = Select-ApplicableRow -Rows $script:Rows
                $script:Ui.Grid.Items.Refresh()
                if ($script:StateFilter -eq 'Selected') { Update-GridFilter }
                Update-ApplyContext
                Set-StatusText "Selezionate $count modifiche disponibili. Incluse opzioni personali: controlla le conseguenze. Nessuna modifica applicata."
            }
        })
    $ui.Clear.Add_Click({
            if ($script:Ui.Tabs.SelectedIndex -eq $script:Tab.Network) { Select-NetworkRow -Value $false; return }
            foreach ($row in $script:Rows) { $row.Selected = $false }
            $script:Ui.Grid.Items.Refresh()
            Update-GridFilter
            Update-ApplyContext
        })
    $ui.Scan.Add_Click({
            Invoke-Guarded {
                $path = Save-ScanReport
                $script:Ui.Report.Text = [IO.File]::ReadAllText($path)
                Update-CatalogView
                $script:Ui.Tabs.SelectedIndex = $script:Tab.Report
                Set-StatusText "Report: $path"
            }
        })
    $ui.Export.Add_Click({ Invoke-Guarded { Export-ProfileFromUi } })
    $ui.Import.Add_Click({ Invoke-Guarded { Import-ProfileFromUi } })

    # Footer
    $ui.Apply.Add_Click({
            Invoke-Guarded {
                $tab = $script:Ui.Tabs.SelectedIndex
                if ($tab -eq $script:Tab.Network) { Invoke-NetworkApply; return }
                if ($tab -eq $script:Tab.Settings) { Invoke-GeneralApply }
            }
        })
    $ui.RestoreSelected.Add_Click({ Invoke-Guarded { Restore-SelectedTweak } })
    $ui.SelectRestore.Add_Click({ Invoke-Guarded { Select-RestoreChoice -Network ($script:Ui.Tabs.SelectedIndex -eq $script:Tab.Network) } })
    $ui.Undo.Add_Click({ Invoke-Guarded { Restore-EverythingFromUi } })
    $ui.Tabs.Add_SelectionChanged({
            param($control, $routed)
            if ($routed.OriginalSource -ne $control -and $routed.Source -ne $control) { return }
            Invoke-Guarded {
                $tab = $script:Ui.Tabs.SelectedIndex
                if ($tab -eq $script:Tab.SpeedHistory) { Update-SpeedHistoryView }
                if ($tab -eq $script:Tab.Network -and -not $script:NetRows) { Update-NetworkView }
                Update-ApplyContext
            }
        })

    # Control Center pages
    foreach ($id in @('Power', 'Storage', 'Graphics', 'GpuApp', 'Software', 'Features', 'Services', 'Diag', 'Updates', 'Audio', 'Apps', 'Debloat', 'Startup', 'Files', 'Backup', 'Audit')) {
        $ui[$id].Tag = $id
        $ui[$id].Add_Click({ param($control) Invoke-PageButton -Button $control })
    }
    $ui.PageSearch.Add_TextChanged({ Update-PageFilter })
    $ui.PageGrid.Add_SelectionChanged({
            $row = $script:Ui.PageGrid.SelectedItem
            if ($row) { $script:Ui.PageDetail.Text = "$($row.Name) | $($row.State)" + [Environment]::NewLine + $row.Detail }
        })
    $ui.PageAction.Add_Click({ Invoke-Guarded { Invoke-PageAction } })
    $ui.PageRefresh.Add_Click({ Invoke-Guarded { if ($script:Page) { Open-ToolPage $script:Page } } })
    $ui.PageCategory.Add_Click({ Show-Category ([string]$script:Ui.PageCategory.Tag) })

    # Network Center
    $ui.Network.Add_Click({
            Invoke-Guarded {
                if (-not $script:NetRows) { Update-NetworkView }
                $script:Ui.Tabs.SelectedIndex = $script:Tab.Network
                Update-ApplyContext
            }
        })
    $ui.NetStart.Add_Click({ Invoke-Guarded { Start-NetworkTest } })
    $ui.NetCancel.Add_Click({
            Invoke-Guarded {
                if ($script:NetJob) {
                    $script:NetState.Stage = 'ANNULLAMENTO'
                    $script:NetState.CancelSource.Cancel()
                    $script:Ui.NetCancel.IsEnabled = $false
                }
            }
        })
    $ui.NetRefresh.Add_Click({ Invoke-Guarded { Update-NetworkView } })
    $ui.NetFlushDNS.Add_Click({
            Invoke-Guarded {
                Assert-NoSpeedTest
                if (Show-ConfirmDialog -Title 'Cache DNS' -Message 'Svuotare la cache DNS locale? Non cambia i server DNS e non promette ping inferiore. La cache verra ricostruita automaticamente.') {
                    Clear-DnsClientCache -ErrorAction Stop
                    Set-StatusText 'Cache DNS svuotata'
                }
            }
        })
    $ui.NetSelectAll.Add_Click({ Invoke-Guarded { Select-NetworkRow -Value $true } })
    $ui.NetClear.Add_Click({ Invoke-Guarded { Select-NetworkRow -Value $false } })
    $ui.NetGrid.AddHandler($click, [Windows.RoutedEventHandler] { param($control, $routed) Sync-TweakCheckbox -Source $control -EventData $routed }, $true)
    $ui.NetApply.Add_Click({ Invoke-Guarded { Invoke-NetworkApply } })
    $ui.NetRestore.Add_Click({ Invoke-Guarded { Restore-NetworkDriver } })
    $ui.NetGrid.Add_SelectionChanged({
            $row = $script:Ui.NetGrid.SelectedItem
            if ($row) { $script:Ui.NetDetail.Text = "$($row.Name) | $($row.VerifiedStatus) | $($row.Before) -> $($row.After) | PWU $($row.PWU)" + [Environment]::NewLine + $row.Note }
        })
    $ui.NetHistory.Add_Click({ Invoke-Guarded { Update-SpeedHistoryView; $script:Ui.Tabs.SelectedIndex = $script:Tab.SpeedHistory } })
    $ui.SpeedHistoryBack.Add_Click({ $script:Ui.Tabs.SelectedIndex = $script:Tab.Network })
    $ui.SpeedHistoryRefresh.Add_Click({ Invoke-Guarded { Update-SpeedHistoryView } })

    $script:NetTimer = New-Object Windows.Threading.DispatcherTimer
    $script:NetTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:NetTimer.Add_Tick({ Update-NetworkTestTick })
    $script:Window.Add_Closed({ Stop-NetworkTest })
    Update-FilterButtonState
}

function Start-MainWindow {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $gpu = (Get-CimInstance Win32_VideoController | ForEach-Object Name) -join ' / '
    $script:Ui.Hardware.Text = "Hardware rilevato: $cpu / $gpu"
    Update-CatalogView
    Update-ApplyContext
    Set-StatusText 'Scansione tweak completata. Nessuna modifica applicata. Seleziona un preset o singole voci.'
    Set-DarkTitleBar -Window $script:Window
    $null = $script:Window.ShowDialog()
}

#endregion

#region Built-in tests (-SelfTest, -UiTest) -------------------------------------------------------

function Invoke-SelfTest {
    <# Isolated HKCU key + temporary state folder: real write, mirrored journal, verify, rollback. #>
    $testKey = 'Software\BrabusPC-Test-' + [guid]::NewGuid().ToString()
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('BrabusTest-' + [guid]::NewGuid().ToString())
    Initialize-AppState -Root $temp
    try {
        $context = [pscustomobject]@{ Build = 99999; IsDomainJoined = $false }
        $one = ConvertTo-TweakRow -Context $context -Definition @{ Name = 'Test'; Category = 'Test'; Level = 'Safe'; Path = $testKey; Key = 'Missing'; Value = 1; Note = 'test' }
        $two = ConvertTo-TweakRow -Context $context -Definition @{ Name = 'Test2'; Category = 'Test'; Level = 'Safe'; Path = $testKey; Key = 'Second'; Value = 0; Note = 'test' }
        $result = Invoke-ApplyBatch -Items @($one, $two)
        if ($result.OK -ne 2) { throw "Apply: $($result.Errors -join '; ')" }
        $records = @(Read-Journal -Journal $script:UserJournal)
        if ($records.Count -ne 2) { throw 'Journal' }
        if ($records[0].BatchId -ne $records[1].BatchId) { throw 'Batch' }
        if ((Get-TweakValue -Path $testKey -Key 'Missing').Value -ne 1) { throw 'Write' }
        Restore-AllUserTweak
        if ((Get-TweakValue -Path $testKey -Key 'Missing').Exists -or (Get-TweakValue -Path $testKey -Key 'Second').Exists -or @(Read-Journal -Journal $script:UserJournal).Count) { throw 'Restore' }

        $catalog = @(Get-TweakCatalog)
        if ($catalog.Count -lt 65) { throw 'Catalog expansion missing' }
        if (@($catalog | Group-Object Path, Key | Where-Object Count -GT 1).Count) { throw 'Duplicate catalog keys' }
        if (@($catalog | Where-Object { $_.PWU -notin @('Low', 'Medium', 'High') -or $_.PWURank -notin @(1, 2, 3) -or -not $_.PWUReason }).Count) { throw 'Invalid PWU' }
        $probe = [pscustomobject]@{ Category = 'Power / CPU'; Path = 'POWER|test'; Key = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Before = '60' }
        if ((Get-PwuRating -Row $probe).Label -ne 'High') { throw 'Conditional High rating failed' }
        $catalog | Group-Object PWU | ForEach-Object { 'PWU {0}: {1}' -f $_.Name, $_.Count }
        'PASS registry test keys, two backups, shared batch, verification, rollback, catalog: ' + $catalog.Count
        $catalog | Group-Object Category | Sort-Object Name | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }
    } finally {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testKey, $false)
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-UiClick {
    param([Parameter(Mandatory)][string]$Name)
    $script:Ui[$Name].RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

function Find-VisualCheckBox {
    param($Element)
    if (-not $Element) { return }
    if ($Element -is [Windows.Controls.CheckBox]) { return $Element }
    for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element); $i++) {
        $found = Find-VisualCheckBox ([Windows.Media.VisualTreeHelper]::GetChild($Element, $i))
        if ($found) { return $found }
    }
}

function Invoke-UiTest {
    <#
        Hidden window, synthetic rows and journal stubs: layout, filters, selection routing, pages,
        Network Center and speed history. No production setting is changed.
    #>
    $window = $script:Window
    $list = $script:Ui.CategoryList
    $list.ItemsSource = @('Tutte', 'App Notifications', 'App Privacy', 'Audio', 'Browser', 'Debloat', 'Explorer', 'Gaming', 'Input', 'Notifications', 'Power / CPU', 'Privacy', 'Startup', 'Taskbar', 'Visual')
    $list.SelectedItem = 'Tutte'
    $script:Ui.Hardware.Text = 'Hardware rilevato: AMD Ryzen 7 5800X 8-Core Processor / AMD Radeon RX 7800 XT'
    $window.Opacity = 0
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Show()
    $window.UpdateLayout()

    # Navigation layout at three window sizes.
    $scroll = $script:Ui.NavScroll
    $nav = $script:Ui.NavStack
    $names = @('Scan', 'Safe', 'Gaming', 'Ultimate', 'SelectAll', 'Clear', 'Export', 'Import', 'Debloat', 'Apps', 'Startup', 'Power', 'Storage', 'Graphics', 'GpuApp', 'Software', 'Features', 'Services', 'Diag', 'Updates', 'Audio', 'Network', 'Backup', 'Undo', 'Files', 'Audit')
    foreach ($size in @(@(1440, 900), @(1280, 820), @(970, 650))) {
        $window.Width = $size[0]
        $window.Height = $size[1]
        $window.UpdateLayout()
        $scroll.ScrollToTop()
        $window.UpdateLayout()
        $items = @($names | ForEach-Object { $script:Ui[$_] })
        for ($i = 0; $i -lt $list.Items.Count; $i++) {
            $container = $list.ItemContainerGenerator.ContainerFromIndex($i)
            if (-not $container -or $container.ActualHeight -lt 1) { throw "Category not laid out: $i" }
            $items += $container
        }
        $initial = 0
        foreach ($item in $items) {
            $bounds = $item.TransformToAncestor($nav).TransformBounds((New-Object Windows.Rect(0, 0, $item.ActualWidth, $item.ActualHeight)))
            if ($bounds.Top -ge 0 -and $bounds.Bottom -le $scroll.ViewportHeight + 1) { $initial++ }
            if ($bounds.Bottom -gt $scroll.ExtentHeight + 1) { throw 'Navigation item outside scroll extent' }
        }
        "MEASURE: $($size[0])x$($size[1]) | visible=$initial of $($items.Count) viewport=$($scroll.ViewportHeight) extent=$($scroll.ExtentHeight) window=$($window.ActualHeight)"
        if ($initial -lt 23) { throw "Too few items visible: $initial" }
        if ($size[0] -eq 1440 -and $initial -ne $items.Count) { throw 'Default layout should fit all navigation items' }
        $scroll.ScrollToEnd()
        $window.UpdateLayout()
        $files = $script:Ui.Files
        $end = $files.TransformToAncestor($nav).TransformBounds((New-Object Windows.Rect(0, 0, $files.ActualWidth, $files.ActualHeight)))
        if ($end.Bottom -gt ($scroll.VerticalOffset + $scroll.ViewportHeight + 1)) { throw 'Last item unreachable' }
        "NAV LAYOUT OK: $($size[0])x$($size[1]) | $initial/$($items.Count) initially visible | overflow $([math]::Round($scroll.ScrollableHeight, 1))"
        $scroll.ScrollToTop()
    }

    # Portable profile on the real catalog (read-only).
    $real = @(Get-TweakCatalog)
    Set-VerificationState -Rows $real
    $network = @(Get-NetworkTweakRow)
    $document = New-PortableProfile -General $real -Network $network
    $resolved = Resolve-PortableProfile -Document $document -General $real -Network $network
    if (-not $document.Selections.Count -or @($document.Selections | Where-Object { $_ -notmatch '^T-[A-F0-9]{32}$' }).Count) { throw 'Portable profile identifiers invalid' }
    $rejected = $false
    try { $null = Resolve-PortableProfile -Document @{ Format = 'BrabusPreset'; Version = 2; Selections = @('arbitrary command') } -General $real -Network @() } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe profile accepted' }
    "PROFILE OK: $($document.Selections.Count) identifiers; $($resolved.Already) already configured; $($resolved.Ambiguous) ambiguous"

    $fixture = @([pscustomobject]@{ Path = 'Software\Test'; Key = 'a'; Selected = $true; CanApply = $true; CanRestore = $false })
    $choices = Get-SelectionMap $fixture
    $fixture[0].CanApply = $false
    $fixture[0].CanRestore = $true
    Restore-SelectionMap -Rows $fixture -Map $choices
    if ($fixture[0].Selected) { throw 'Applied tweak reselected for restore' }
    $fixture[0].CanApply = $true
    $fixture[0].CanRestore = $false
    Restore-SelectionMap -Rows $fixture -Map $choices
    if (-not $fixture[0].Selected) { throw 'Pending choice lost' }
    'PROFILE SELECTION PRESERVATION OK'

    # Synthetic catalog and journal stub (script scope, like v2.0): this process exits right after.
    function script:Read-Journal { param($Journal) $null = $Journal; [pscustomobject]@{ Path = 'Software\Test'; Key = 'four' } }
    $script:Rows = @(
        [pscustomobject]@{ Name = 'One'; Path = 'Software\Test'; Key = 'one'; Status = $script:StatusAvailable; Selected = $false; PWU = 'High' },
        [pscustomobject]@{ Name = 'Two'; Path = 'Software\Test'; Key = 'two'; Status = $script:StatusAvailable; Selected = $false; PWU = 'Medium' },
        [pscustomobject]@{ Name = 'Already'; Path = 'Software\Test'; Key = 'three'; Status = $script:StatusConfigured; Selected = $false; PWU = 'Low' },
        [pscustomobject]@{ Name = 'Pending'; Path = 'Software\Test'; Key = 'four'; Status = $script:StatusAvailable; Selected = $false; PWU = 'Low' }
    )
    $grid = $script:Ui.Grid
    $grid.ItemsSource = $script:Rows
    Invoke-UiClick 'SelectAll'
    if (-not $script:Rows[0].Selected -or -not $script:Rows[1].Selected -or $script:Rows[2].Selected -or $script:Rows[3].Selected) { throw 'Select all event failed' }
    Invoke-UiClick 'Clear'
    if (@($script:Rows | Where-Object Selected).Count) { throw 'Clear event failed' }
    Invoke-UiClick 'Safe'
    if ($script:Ui.Apply.IsEnabled) { throw 'Preset selected rows without Level' }
    $script:Rows[0] | Add-Member -NotePropertyName Category -NotePropertyValue 'Gaming'
    $script:Rows[1] | Add-Member -NotePropertyName Category -NotePropertyValue 'Privacy'
    $script:Rows[2] | Add-Member -NotePropertyName Category -NotePropertyValue 'Gaming'
    $script:Rows[3] | Add-Member -NotePropertyName Category -NotePropertyValue 'Privacy'
    Invoke-UiClick 'PWUHigh'
    if (@($grid.ItemsSource).Count -ne 1 -or $grid.ItemsSource[0].Name -ne 'One') { throw 'PWU High filter failed' }
    Invoke-UiClick 'StateDone'
    if (@($grid.ItemsSource).Count) { throw 'Combined filter failed' }
    Invoke-UiClick 'ResetFilters'
    if (@($grid.ItemsSource).Count -ne 4) { throw 'Reset filter failed' }
    $script:Ui.Filter.Text = 'One Gaming'
    if (@($grid.ItemsSource).Count -ne 1) { throw 'Token search failed' }
    $script:Ui.Filter.Text = ''
    Update-Dashboard
    if ($script:Ui.Done.Text -ne '1 / 4' -or $script:Ui.Pending.Text -ne '1') { throw 'Dashboard separate counters failed' }
    Show-Category 'Gaming'
    if (@($grid.ItemsSource).Count -ne 2) { throw 'Category filter failed' }
    Invoke-UiClick 'SelectPage'
    if (-not $script:Rows[0].Selected -or $script:Rows[1].Selected) { throw 'Visible selection failed' }
    $script:Rows[0] | Add-Member -NotePropertyName Level -NotePropertyValue 'Safe'
    Invoke-UiClick 'Clear'
    Invoke-UiClick 'Safe'
    if (-not $script:Rows[0].Selected -or -not $script:Ui.Apply.IsEnabled) { throw 'Preset must enable the Apply button' }
    'PASS: preset selection enables Apply'
    Invoke-UiClick 'Clear'
    Show-Category 'Tutte'

    foreach ($id in @('Apps', 'Debloat', 'Startup', 'Power', 'Storage', 'Graphics', 'GpuApp', 'Software', 'Features', 'Services', 'Updates', 'Audio', 'Diag', 'Backup', 'Files', 'Audit')) {
        Invoke-UiClick $id
        if ($script:Page -ne $id -or $script:Ui.Tabs.SelectedIndex -ne $script:Tab.ControlCenter -or $script:Ui.Status.Text -like 'ERRORE:*') {
            throw "Page navigation failed: $id | $($script:Ui.Status.Text)"
        }
        "PAGE OK: $id ($($script:PageRows.Count))"
    }
    Invoke-UiClick 'Network'
    if ($script:Ui.Tabs.SelectedIndex -ne $script:Tab.Network -or $script:Ui.Status.Text -like 'ERRORE:*') { throw "Network page failed: $($script:Ui.Status.Text)" }
    Show-NetworkTestState @{ Stage = 'TEST'; Progress = 100; Samples = @(10, 13, 12, 15); Down = 100.5; Up = 20; Ping = 12.5; Jitter = 2; Loss = 0; DownLoadedPing = 45; UpLoadedPing = 60 }
    if ($script:Ui.NetDown.Text -ne '100.5' -or $script:Ui.NetTrace.Points.Count -ne 4 -or $script:Ui.NetDownLoaded.Text -ne '45' -or $script:Ui.NetUpLoaded.Text -ne '60') { throw 'Network HUD render failed' }

    $realNetRows = $script:NetRows
    $script:NetRows = @(
        [pscustomobject]@{ Name = 'Available1'; Selected = $false; CanSelect = $true; Status = $script:StatusAvailable },
        [pscustomobject]@{ Name = 'Available2'; Selected = $false; CanSelect = $true; Status = $script:StatusAvailable },
        [pscustomobject]@{ Name = 'Configured'; Selected = $false; CanSelect = $false; Status = $script:StatusConfigured },
        [pscustomobject]@{ Name = 'Backup'; Selected = $false; CanSelect = $false; Status = $script:StatusAvailable }
    )
    $script:Ui.NetGrid.ItemsSource = $script:NetRows
    Invoke-UiClick 'NetSelectAll'
    if (@($script:NetRows | Where-Object Selected).Count -ne 2 -or $script:NetRows[2].Selected -or $script:NetRows[3].Selected -or $script:Ui.NetSelectedCount.Text -ne '2 selezionati') { throw 'Network select all failed' }
    Invoke-UiClick 'NetClear'
    if (@($script:NetRows | Where-Object Selected).Count -or $script:Ui.NetSelectedCount.Text -ne '0 selezionati') { throw 'Network clear failed' }
    $script:NetRows = $realNetRows
    $script:Ui.NetGrid.ItemsSource = $realNetRows

    $savedHistory = $script:Paths.SpeedHistory
    $script:Paths.SpeedHistory = Join-Path ([IO.Path]::GetTempPath()) ('BrabusHistoryTest-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $history = @{ TestId = 'test1'; Stage = 'COMPLETATO'; Elapsed = 26.5; Down = 100; Up = 20; Ping = 30; Jitter = 4; Loss = 0; NetworkConfig = 'testA' }
        Save-SpeedResult -State $history
        Save-SpeedResult -State $history
        $history.TestId = 'test2'; $history.Down = 110; $history.NetworkConfig = 'testB'
        Save-SpeedResult -State $history
        $history.TestId = 'partial'; $history.Stage = 'PARZIALE'; $history.Up = $null
        Save-SpeedResult -State $history
        Invoke-UiClick 'NetHistory'
        if (@(Read-SpeedHistory).Count -ne 3 -or $script:Ui.Tabs.SelectedIndex -ne $script:Tab.SpeedHistory -or $script:Ui.SpeedHistoryCompare.Text -notmatch '\+10[,.]00') { throw 'Speed history test failed' }
        Invoke-UiClick 'SpeedHistoryBack'
        if ($script:Ui.Tabs.SelectedIndex -ne $script:Tab.Network) { throw 'History back failed' }
        'HISTORY OK - persistence, dedup, partial exclusion, comparison'
    } finally {
        Remove-Item -LiteralPath $script:Paths.SpeedHistory -ErrorAction SilentlyContinue
        $script:Paths.SpeedHistory = $savedHistory
    }

    $script:NetRows = @([pscustomobject]@{ Name = 'Network fixture'; Path = 'NET|test'; Key = 'test'; Selected = $false; CanSelect = $true; Status = $script:StatusAvailable })
    $script:Ui.NetGrid.ItemsSource = $script:NetRows
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Network
    Invoke-UiClick 'SelectAll'
    if (-not $script:NetRows[0].Selected -or $script:Ui.Apply.Content -ne 'APPLICA TWEAK RETE (1)') { throw 'Network sidebar route failed' }
    $script:RouteTest = 0
    function script:Invoke-NetworkApply { $script:RouteTest = @($script:NetRows | Where-Object Selected).Count }
    Invoke-UiClick 'Apply'
    if ($script:RouteTest -ne 1) { throw 'Footer network dispatch failed' }
    Invoke-UiClick 'Clear'
    if ($script:NetRows[0].Selected -or $script:Ui.Apply.IsEnabled) { throw 'Network clear route failed' }
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Settings
    if ($script:Ui.Apply.Content -ne 'APPLICA MODIFICHE SELEZIONATE') { throw "General footer route failed: $($script:Ui.Apply.Content) | $($script:Ui.Status.Text)" }
    'PASS: footer routes network selection; sidebar select and clear; general context restored'

    $script:NetRows = @(
        [pscustomobject]@{ Name = 'Apply fixture'; Path = 'NET|test'; Key = 'a'; Selected = $false; CanSelect = $true; CanApply = $true; CanRestore = $false; Status = $script:StatusAvailable },
        [pscustomobject]@{ Name = 'Restore fixture 1'; Path = 'NET|test'; Key = 'b'; Selected = $false; CanSelect = $true; CanApply = $false; CanRestore = $true; Status = $script:StatusConfigured },
        [pscustomobject]@{ Name = 'Restore fixture 2'; Path = 'NET|test'; Key = 'c'; Selected = $false; CanSelect = $true; CanApply = $false; CanRestore = $true; Status = $script:StatusConfigured }
    )
    $script:Ui.NetGrid.ItemsSource = $script:NetRows
    $script:Ui.Tabs.SelectedIndex = $script:Tab.Network
    Invoke-UiClick 'SelectRestore'
    if (@(Get-ActionRow -Network $true -Restore $true).Count -ne 2 -or @(Get-ActionRow -Network $true -Restore $false).Count -ne 0 -or -not $script:Ui.RestoreSelected.IsEnabled) { throw 'Restore selection failed' }
    $script:RestoreRoute = 0
    function script:Restore-SelectedTweak { $script:RestoreRoute = @(Get-ActionRow -Network $true -Restore $true).Count }
    Invoke-UiClick 'RestoreSelected'
    if ($script:RestoreRoute -ne 2) { throw 'Restore routing failed' }
    Invoke-UiClick 'SelectAll'
    if (@(Get-ActionRow -Network $true -Restore $false).Count -ne 1 -or @(Get-ActionRow -Network $true -Restore $true).Count) { throw 'Apply selection isolation failed' }
    'PASS: separate multi-apply and selective-restore routing'

    $window.Width = 1440
    $window.Height = 900
    $window.UpdateLayout()
    Invoke-UiClick 'Clear'
    $netGrid = $script:Ui.NetGrid
    foreach ($row in @($script:NetRows[1], $script:NetRows[2])) {
        $netGrid.ScrollIntoView($row)
        $netGrid.BringIntoView()
        $window.UpdateLayout()
        $netGrid.UpdateLayout()
        $check = Find-VisualCheckBox ($netGrid.ItemContainerGenerator.ContainerFromItem($row))
        if (-not $check -or -not $check.IsEnabled) { throw 'Rendered checkbox not available' }
        $null = $check.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($check, @())
    }
    if (@(Get-ActionRow -Network $true -Restore $true).Count -ne 2 -or $script:Ui.RestoreSelected.Content -ne 'RIPRISTINA SELEZIONATI (2)') { throw 'Real checkbox multiselect did not propagate' }
    'PASS: two rendered network checkboxes clicked, correct backing state and footer count'
    'NETWORK MULTISELECT OK'
    $window.Close()
    'UI TEST OK - PWU, combined filters, token search, separate counters, category filters, presets, select visible, all integrated pages'
}

#endregion

#region Entry point -------------------------------------------------------------------------------

function Assert-StaThread {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'La GUI richiede un thread STA: avvia con powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1'
    }
}

function Invoke-BrabusMain {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Scan,
        [switch]$SelfTest,
        [switch]$Undo,
        [switch]$UiTest,
        [switch]$ReleaseCheck,
        [string]$ExportCurrentProfile
    )
    Initialize-NativeInterop
    $script:IsAdmin = Test-IsAdministrator
    if ($SelfTest) { Invoke-SelfTest; return }
    Initialize-AppState

    # One interactive instance per user; test and report modes get a private mutex.
    $isolated = $UiTest -or $ReleaseCheck -or $ExportCurrentProfile
    $mutexName = if ($isolated) { 'Local\BrabusPCDebloater-UiTest-' + [guid]::NewGuid().ToString() } else { 'Local\BrabusPCDebloater' }
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    try {
        $locked = $mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $locked = $true
    }
    if (-not $locked) {
        $mutex.Dispose()
        throw 'BRABUS UTIL e gia aperto: chiudi l altra finestra prima di avviarne una nuova.'
    }
    try {
        if (-not $isolated -and -not $Scan) { Invoke-LegacyMigration -Journal $script:UserJournal }
        if ($Undo) {
            Restore-AllUserTweak
            'Ripristino utente/energia completato. Per i driver usa Network Center o Ripristina tutto nella GUI.'
            return
        }
        if ($Scan) { Save-ScanReport; return }
        if ($ReleaseCheck -or $ExportCurrentProfile) { Invoke-ReleaseCheck -ExportPath $ExportCurrentProfile; return }
        Assert-StaThread
        Initialize-MainWindow
        if ($UiTest) { Invoke-UiTest; return }
        Start-MainWindow
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# Dot-sourcing (". .\BrabusDebloater.ps1") only loads the functions: used by the Pester tests.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BrabusMain @PSBoundParameters
}

#endregion
