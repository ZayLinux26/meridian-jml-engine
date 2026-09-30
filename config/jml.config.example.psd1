# Meridian Financial Group | JML engine configuration
# Copy to jml.config.psd1 (git-ignored) and fill in the CHANGEME values.
@{
    Organization    = 'Meridian Financial Group'

    AD              = @{
        # Leave Server empty to use the local domain controller / DC locator.
        Server     = ''
        BaseOU     = 'OU=Meridian,DC=meridianfg,DC=internal'
        UsersOU    = 'OU=Users,OU=Meridian,DC=meridianfg,DC=internal'
        DisabledOU = 'OU=Disabled Users,OU=Meridian,DC=meridianfg,DC=internal'
        # Must be a domain verified in your Entra tenant so synced UPNs line up.
        UpnSuffix  = 'CHANGEME.onmicrosoft.com'
    }

    Graph           = @{
        TenantId              = 'CHANGEME-tenant-guid'
        ClientId              = 'CHANGEME-app-client-id'
        CertificateThumbprint = 'CHANGEME-thumbprint'
        UsageLocation         = 'US'
        ContractorPrefix      = 'c-'
    }

    Safety          = @{
        # Circuit breaker: an apply run aborts before any change if the plan
        # contains more leavers than either limit allows.
        MaxLeaversPerRun = 10
        MaxLeaverPercent = 25
        # Accounts are pre-created (disabled) up to this many days before start.
        PreHireDays      = 14
    }

    AccessModelPath = 'access-model.json'

    Paths           = @{
        Logs       = '../output/logs'
        Journal    = '../output/journal'
        Reports    = '../output/reports'
        Simulation = '../output/simulation'
    }
}
