@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Internal helpers named New-/Set-/Remove-/Restore-* do not need -WhatIf: every change in
        # this GUI tool is confirmed through an explicit dialog that lists each value before writing.
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules        = @{
        # The tool targets Windows PowerShell 5.1; tests also run on PowerShell 7.
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
