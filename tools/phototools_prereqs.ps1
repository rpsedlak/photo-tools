<#
.SYNOPSIS
Make sure the tools photo-tools needs are installed (Windows 11).

.DESCRIPTION
phototools_prereqs.ps1 (Windows PowerShell version of phototools_prereqs.sh) checks for:

    exiftool             winget OliverBetz.ExifTool   (phototools_import_photos.ps1, phototools_rename_nef.ps1)
    Adobe DNG Converter  winget Adobe.DNGConverter    (phototools_import_photos.ps1)

and, for phototools_upload_azure.ps1:

    Azure CLI            winget Microsoft.AzureCLI
    azcopy               winget Microsoft.Azure.AZCopy.10

Anything missing is installed with winget (Windows Package Manager, included
with Windows 11). winget itself is not installed automatically; if it's missing
you're told how to get it. Some installers ask for administrator approval (a
UAC prompt). Unlike the macOS version there is no jq: PowerShell reads JSON itself.

Exit status: 0 when everything is ready, 1 otherwise.

Works with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER CheckOnly
Check only: report what's missing, install nothing.

.EXAMPLE
tools\phototools_prereqs.ps1 -CheckOnly

.EXAMPLE
tools\phototools_prereqs.ps1
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    [Console]::Error.WriteLine('Error: this is the Windows version of photo-tools; use phototools_prereqs.sh on macOS.')
    exit 1
}

$DngConverterEnv = $env:DNG_CONVERTER

function Get-DngConverterPath {
    $paths = @()
    if ($DngConverterEnv) { $paths += $DngConverterEnv }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        $paths += (Join-Path $pf 'Adobe\Adobe DNG Converter.exe')
        $paths += (Join-Path $pf 'Adobe\Adobe DNG Converter\Adobe DNG Converter.exe')
    }
    $paths
}

# A program installed during this run is not on this session's PATH yet; re-read it.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $links = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    $env:Path = (@($machine, $user, $links, $env:Path) | Where-Object { $_ }) -join ';'
}

$script:problems = 0
$script:needWinget = @()

function Write-Ok      { param([string]$Text) Write-Host ('OK       ' + $Text) }
function Write-Missing { param([string]$Text) Write-Host ('MISSING  ' + $Text) }

$winget = Get-Command winget -ErrorAction SilentlyContinue

# $Label = display name, $Id = winget package id
function Install-WithWinget {
    param([string]$Label, [string]$Id)
    if ($CheckOnly) {
        Write-Host "         install with: winget install --id $Id -e"
        return $false
    }
    if (-not $winget) {
        $script:needWinget += $Label
        return $false
    }
    Write-Host "Installing $Label with winget..."
    & winget install --id $Id -e --accept-package-agreements --accept-source-agreements
    Update-SessionPath
    return ($LASTEXITCODE -eq 0)
}

# ---------- winget -----------------------------------------------------------
if ($winget) {
    $wingetVersion = (& winget --version 2>$null | Select-Object -First 1)
    Write-Ok "winget $wingetVersion  ($($winget.Source))"
} else {
    Write-Missing 'winget (needed only to install anything missing below)'
}

# ---------- exiftool ---------------------------------------------------------
function Test-ExifTool {
    $p = Get-Command exiftool -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    Write-Ok "exiftool $(& exiftool -ver 2>$null)  ($($p.Source))"
    return $true
}

if (-not (Test-ExifTool)) {
    Write-Missing 'exiftool'
    if (-not ((Install-WithWinget 'exiftool' 'OliverBetz.ExifTool') -and (Test-ExifTool))) {
        if (-not $CheckOnly -and $winget) {
            Write-Host '         If it was just installed, open a new PowerShell window so it is on your PATH, then re-run this script.'
        }
        $script:problems++
    }
}

# ---------- Adobe DNG Converter ----------------------------------------------
function Test-DngConverter {
    foreach ($p in Get-DngConverterPath) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            Write-Ok "Adobe DNG Converter  ($p)"
            return $true
        }
    }
    return $false
}

if (-not (Test-DngConverter)) {
    $expected = if ($DngConverterEnv) { $DngConverterEnv } else { (Get-DngConverterPath)[0] }
    Write-Missing "Adobe DNG Converter (not found at $expected)"
    if (-not ((Install-WithWinget 'Adobe DNG Converter' 'Adobe.DNGConverter') -and (Test-DngConverter))) {
        if (-not $CheckOnly -and $winget) {
            Write-Host "         Still not found at $expected. If you installed it elsewhere, set DNG_CONVERTER to its path."
        }
        $script:problems++
    }
}

# ---------- Azure upload tools (phototools_upload_azure.ps1) ----------------------------
$azureTools = @(
    @{ Command = 'az';     Id = 'Microsoft.AzureCLI';         Label = 'Azure CLI' },
    @{ Command = 'azcopy'; Id = 'Microsoft.Azure.AZCopy.10';  Label = 'azcopy' }
)
foreach ($t in $azureTools) {
    $p = Get-Command $t.Command -ErrorAction SilentlyContinue
    if ($p) {
        Write-Ok "$($t.Label)  ($($p.Source))"
        continue
    }
    Write-Missing $t.Label
    if ((Install-WithWinget $t.Label $t.Id) -and (Get-Command $t.Command -ErrorAction SilentlyContinue)) {
        Write-Ok "$($t.Label)  ($((Get-Command $t.Command).Source))"
    } else {
        if (-not $CheckOnly -and $winget) {
            Write-Host '         If it was just installed, open a new PowerShell window so it is on your PATH, then re-run this script.'
        }
        $script:problems++
    }
}

# ---------- summary ----------------------------------------------------------
Write-Host ''
if ($script:needWinget.Count -gt 0) {
    Write-Host ('winget is needed to install: ' + ($script:needWinget -join ', '))
    Write-Host 'Install "App Installer" from the Microsoft Store (it provides winget), then re-run this script.'
    Write-Host ''
}
if ($script:problems -eq 0) {
    Write-Host 'All prerequisites are installed.'
    exit 0
}
Write-Host "$($script:problems) prerequisite(s) not ready."
exit 1
