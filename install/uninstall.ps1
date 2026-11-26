<#
.SYNOPSIS
Remove the photo-tools PowerShell scripts installed by install.ps1 (Windows 11).

.DESCRIPTION
uninstall.ps1 (Windows PowerShell version of uninstall.sh) removes every
photo-tools script from the install folder, by default
%LOCALAPPDATA%\photo-tools\bin: the known phototools_*.ps1 names and any *.ps1
that the repository's tool directories (workflow\, cloud\, tools\, ...) provide.
Other files in the folder are left alone. No administrator rights are needed.

When the folder is left empty it is deleted and removed from your user PATH
(use -KeepPath to leave the PATH alone).

Works with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER DryRun
Dry run: show what would be uninstalled, change nothing.

.PARAMETER VerboseLog
Show why each script is (or is not) removed (default: off). (This is not the
common -Verbose parameter.)

.PARAMETER Destination
Uninstall from somewhere else (default: %LOCALAPPDATA%\photo-tools\bin).

.PARAMETER KeepPath
Do not remove the destination folder from your user PATH.

.EXAMPLE
install\uninstall.ps1 -DryRun

.EXAMPLE
install\uninstall.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$VerboseLog,
    [string]$Destination,
    [switch]$KeepPath
)

$ErrorActionPreference = 'Continue'

function Stop-Uninstall {
    param([string]$Message)
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}
function Write-VLog { param([string]$Text) if ($VerboseLog) { [Console]::Error.WriteLine("verbose: $Text") } }

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
if (-not $Destination) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local' }
    $Destination = Join-Path (Join-Path $base 'photo-tools') 'bin'
}
$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$root = [IO.Path]::GetPathRoot($Destination)
if ($Destination.Length -gt $root.Length) { $Destination = $Destination.TrimEnd('\', '/') }

Write-VLog "destination: $Destination; dry run: $([int][bool]$DryRun)"

# Known scripts, even if they no longer exist in the source.
$scriptsToRemove = New-Object System.Collections.Generic.List[string]
foreach ($name in 'import_photos', 'rename_nef', 'rename_dng', 'upload_azure', 'report_azure', 'prune_nef',
                  'archive_container', 'unarchive_container', 'prereqs', 'update') {
    $scriptsToRemove.Add("phototools_$name.ps1")
}

# Scripts the repository provides: <repo>\<tool-dir>\<script>.ps1
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($dir in (Get-ChildItem -LiteralPath $repo -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' -and $_.Name -ne 'install' } | Sort-Object Name)) {
    foreach ($f in (Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.ps1' | Sort-Object Name)) {
        if (-not $scriptsToRemove.Contains($f.Name)) { $scriptsToRemove.Add($f.Name) }
    }
}

$removed = 0
foreach ($script in $scriptsToRemove) {
    $target = Join-Path $Destination $script
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-VLog "removing $target"
        if ($DryRun) {
            Write-Host "WOULD remove $target"
            $removed++
            continue
        }
        try {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            Write-Host "Removed  $script from $Destination"
            $removed++
        } catch {
            Stop-Uninstall "could not remove $script"
        }
    } else {
        Write-VLog "$target not found (skipped)"
    }
}

# An empty install folder is no longer needed, and neither is its PATH entry.
$folderEmpty = (Test-Path -LiteralPath $Destination -PathType Container) -and
    -not (Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
$dropFolder = $folderEmpty -and -not $DryRun
if ($dropFolder) {
    try { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop; Write-VLog "removed empty folder $Destination" }
    catch { Write-VLog "could not remove $Destination" }
}
if ($onWindows -and -not $KeepPath -and ($folderEmpty -or -not (Test-Path -LiteralPath $Destination))) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userEntries = @($userPath -split ';' | Where-Object { $_ })
    $kept = @($userEntries | Where-Object { $_.TrimEnd('\', '/') -ne $Destination })
    if ($kept.Count -ne $userEntries.Count) {
        if ($DryRun) {
            Write-Host "WOULD remove $Destination from your user PATH"
        } else {
            [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
            Write-Host "Removed $Destination from your user PATH."
        }
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run complete - nothing was changed.'
} elseif ($removed -eq 0) {
    Write-Host "No photo-tools scripts found to remove from $Destination."
} else {
    Write-Host "Removed $removed script(s) from $Destination."
}
exit 0
