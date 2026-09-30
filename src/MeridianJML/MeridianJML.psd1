@{
    RootModule           = 'MeridianJML.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6f1d7c2e-3b8a-4e5f-9a1c-2d7e8b4f6a90'
    Author               = 'Isaiah Herard (ZayLinux26)'
    CompanyName          = 'Meridian Financial Group (fictional lab)'
    Copyright            = '(c) 2026 Isaiah Herard. MIT License.'
    Description          = 'Joiner-Mover-Leaver identity lifecycle engine for hybrid Active Directory and Microsoft Entra ID. Desired-state planning, atomic joiner/mover transactions with compensating rollback, fail-secure leaver containment, and a full audit journal.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Invoke-JmlRun'
        'Undo-JmlRun'
        'Show-JmlRun'
        'Connect-JmlGraph'
        'Import-JmlHrFeed'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('IAM', 'IGA', 'JML', 'EntraID', 'ActiveDirectory', 'MicrosoftGraph', 'Identity')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
