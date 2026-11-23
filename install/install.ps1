<#
.SYNOPSIS
Install the photo-tools PowerShell scripts for the current user (Windows 11).

.DESCRIPTION
install.ps1 (Windows PowerShell version of install.sh) first runs
tools\phototools_prereqs.ps1, which installs anything missing (exiftool, Adobe DNG
Converter, Azure CLI and azcopy) with winget; it stops if that fails.

Then it copies every *.ps1 in the repository's tool directories (workflow\,
cloud\, tools\, ...) into one folder, by default
%LOCALAPPDATA%\photo-tools\bin, and adds that folder to your user PATH so the
scripts run by name (e.g. phototools_import_photos.ps1 -EventName "My Event"). No
administrator rights are needed.

Re-run after pulling updates; installed copies are replaced.

Works with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER DryRun
Report missing prerequisites and show what would be installed, change nothing.

.PARAMETER Destination
Install somewhere else (default: %LOCALAPPDATA%\photo-tools\bin).

.PARAMETER NoPath
Do not add the destination folder to your user PATH.

.EXAMPLE
install\install.ps1 -DryRun

.EXAMPLE
install\install.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Destination,
    [switch]$NoPath
)

$ErrorActionPreference = 'Continue'

function Stop-Install {
    param([string]$Message)
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
if (-not $Destination) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local' }
    $Destination = Join-Path (Join-Path $base 'photo-tools') 'bin'
}
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $repo 'cloud') 'phototools_upload_azure.ps1') -PathType Leaf)) {
    Stop-Install 'required script cloud\phototools_upload_azure.ps1 not found.'
}

# Tool scripts live one level down: <repo>\<tool-dir>\<script>.ps1
$scripts = @()
foreach ($dir in (Get-ChildItem -LiteralPath $repo -Directory | Where-Object { $_.Name -notlike '.*' -and $_.Name -ne 'install' } | Sort-Object Name)) {
    $scripts += @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.ps1' | Sort-Object Name)
}
if ($scripts.Count -eq 0) { Stop-Install "no scripts found in $repo." }

# Everything lands in one directory, so names must be unique.
$dupes = @($scripts | Group-Object Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupes.Count -gt 0) {
    Stop-Install ("these names exist in more than one tool directory and would overwrite each other:`n" + ($dupes -join "`n"))
}

Write-Host 'Checking prerequisites...'
$prereqs = Join-Path (Join-Path $repo 'tools') 'phototools_prereqs.ps1'
if ($DryRun) {
    & $prereqs -CheckOnly
} else {
    & $prereqs
    if ($LASTEXITCODE -ne 0) { Stop-Install 'prerequisites are not ready (see above). Fix them and re-run.' }
}
Write-Host ''

if ($DryRun) {
    Write-Host "WOULD create $Destination (if missing)"
} else {
    try {
        New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    } catch {
        Stop-Install "cannot create $Destination"
    }
}

$installed = 0
foreach ($f in $scripts) {
    $target = Join-Path $Destination $f.Name
    $shown = $f.FullName.Substring($repo.Length).TrimStart('\', '/')
    if ($DryRun) {
        Write-Host "WOULD copy $shown -> $target"
        $installed++
        continue
    }
    try {
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
        Write-Host "Installed  $shown -> $target"
        $installed++
    } catch {
        Stop-Install "could not install $($f.Name)"
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run complete - nothing was changed.'
} else {
    Write-Host "Installed $installed script(s) to $Destination."
}

# Put the destination on the user PATH, so the scripts run by name.
$pathEntries = @($env:Path -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
$onPath = $pathEntries -contains $Destination
if (-not $onPath -and $onWindows) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userEntries = @($userPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
    if ($NoPath) {
        Write-Host "Note: $Destination is not in your PATH. Add it to run the tools by name."
    } elseif ($DryRun) {
        if ($userEntries -notcontains $Destination) { Write-Host "WOULD add $Destination to your user PATH" }
    } else {
        if ($userEntries -notcontains $Destination) {
            $newPath = (@($userEntries) + $Destination) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "Added $Destination to your user PATH. Open a new PowerShell window to use it."
        }
        $env:Path = "$env:Path;$Destination"
    }
} elseif (-not $onPath) {
    Write-Host "Note: $Destination is not in your PATH. Add it to run the tools by name."
}

# Scripts only run when PowerShell's execution policy allows it.
if ($onWindows) {
    $policy = Get-ExecutionPolicy
    if ($policy -in 'Restricted', 'AllSigned') {
        Write-Host ''
        Write-Host "Note: your PowerShell execution policy is $policy, which blocks these scripts."
        Write-Host '      Allow locally installed scripts with:'
        Write-Host '          Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    }
}
exit 0
