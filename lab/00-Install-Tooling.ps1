<#
.SYNOPSIS
    Installs the latest PowerShell 7, Git and the Graph authentication module on MFG-DC01.
.DESCRIPTION
    Run in the built-in Windows PowerShell 5.1 (as Administrator) right after
    the VM is created. Everything after this runs in PowerShell 7 (pwsh).
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path $env:TEMP 'mfg-tooling'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host 'Installing the latest stable PowerShell 7...' -ForegroundColor Cyan
# The current Microsoft.Graph modules need the newest PowerShell runtime, so
# use Microsoft's installer script rather than pinning an older MSI.
Invoke-Expression "& { $(Invoke-RestMethod https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"

Write-Host 'Installing Git for Windows...' -ForegroundColor Cyan
$gitExe = Join-Path $tmp 'git.exe'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' -OutFile $gitExe
Start-Process $gitExe -Wait -ArgumentList '/VERYSILENT /NORESTART'

Write-Host 'Installing Microsoft.Graph.Authentication for PowerShell 7...' -ForegroundColor Cyan
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module Microsoft.Graph.Authentication -Scope AllUsers -Force; Install-Module Pester -MinimumVersion 5.5 -Scope AllUsers -Force -SkipPublisherCheck"

Write-Host "`nDone. Close this window and open 'PowerShell 7' from the Start menu." -ForegroundColor Green
