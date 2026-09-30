#Requires -Version 7.2
Set-StrictMode -Version 3.0

# Module-wide run context. Every run resets it through Initialize-JmlContext.
$script:Jml = @{
    Config         = $null
    AccessModel    = $null
    Provider       = 'Live'
    RunId          = $null
    LogFile        = $null
    FaultInjection = $null
    SimState       = $null
    SimStatePath   = $null
    EntraGroupMap  = @{}   # displayName -> id (managed groups only)
    EntraGroupById = @{}   # id -> displayName
    EntraCache     = @{}
    Quiet          = $false
}

foreach ($folder in @('Private', 'Public')) {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in (Get-ChildItem -Path $path -Filter '*.ps1' | Sort-Object Name)) {
        . $file.FullName
    }
}
