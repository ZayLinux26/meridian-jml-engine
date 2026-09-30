<#
.SYNOPSIS
    Installs PowerShell 7, Git and the Graph authentication module on MFG-DC01.
.DESCRIPTION
    Run in the built-in Windows PowerShell 5.1 (as Administrator) right after
    the VM is created. Everything after this runs in PowerShell 7 (pwsh).
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path $env:TEMP 'mfg-tooling'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host 'Installing PowerShell 7.4 LTS...' -ForegroundColor Cyan
$pwshMsi = Join-Path $tmp 'pwsh.msi'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi' -OutFile $pwshMsi
Start-Process msiexec.exe -Wait -ArgumentList "/i `"$pwshMsi`" /qn ADD_PATH=1 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1"

Write-Host 'Installing Git for Windows...' -ForegroundColor Cyan
$gitExe = Join-Path $tmp 'git.exe'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' -OutFile $gitExe
Start-Process $gitExe -Wait -ArgumentList '/VERYSILENT /NORESTART'

Write-Host 'Installing Microsoft.Graph.Authentication for PowerShell 7...' -ForegroundColor Cyan
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module Microsoft.Graph.Authentication -Scope AllUsers -Force; Install-Module Pester -MinimumVersion 5.5 -Scope AllUsers -Force -SkipPublisherCheck"

Write-Host "`nDone. Close this window and open 'PowerShell 7' from the Start menu." -ForegroundColor Green
