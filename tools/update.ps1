<#
.SYNOPSIS
Install missing prerequisites, then update photo-tools dependencies (Windows 11).

.DESCRIPTION
update.ps1 (Windows PowerShell version of update.sh) first runs prereqs.ps1 to
install anything missing, then upgrades the winget-managed dependencies used by
this repository: exiftool, Adobe DNG Converter, Azure CLI and azcopy. Programs
that were not installed with winget are left alone.

Works with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
update.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Stop-Update {
    param([string]$Message)
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Stop-Update 'this is the Windows version of photo-tools; use update.sh on macOS.' }

$prereqs = Join-Path $PSScriptRoot 'prereqs.ps1'
if (-not (Test-Path -LiteralPath $prereqs -PathType Leaf)) {
    Stop-Update 'prereqs.ps1 not found. Reinstall photo-tools using install\install.ps1.'
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Stop-Update 'winget is required to update dependencies. Install "App Installer" from the Microsoft Store.'
}

Write-Host 'Updating winget package sources...'
& winget source update
if ($LASTEXITCODE -ne 0) { Stop-Update 'winget could not update its package sources.' }

Write-Host 'Checking prerequisites...'
& $prereqs
if ($LASTEXITCODE -ne 0) { Stop-Update 'prerequisites are not ready (see above).' }

$packages = @(
    @{ Id = 'OliverBetz.ExifTool';        Label = 'exiftool' },
    @{ Id = 'Adobe.DNGConverter';         Label = 'Adobe DNG Converter' },
    @{ Id = 'Microsoft.AzureCLI';         Label = 'Azure CLI' },
    @{ Id = 'Microsoft.Azure.AZCopy.10';  Label = 'azcopy' }
)
foreach ($p in $packages) {
    & winget list --id $p.Id -e --accept-source-agreements *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$($p.Label) is not managed by winget; skipping its update."
        continue
    }
    Write-Host "Updating $($p.Label)..."
    & winget upgrade --id $p.Id -e --accept-package-agreements --accept-source-agreements
    # 0 = upgraded; a package with no newer version is not an error for us.
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne -1978335189) {   # 0x8A15002B: no applicable update found
        Stop-Update "$($p.Label) upgrade failed (winget exit code $rc)."
    }
}

Write-Host 'Dependencies are up to date.'
