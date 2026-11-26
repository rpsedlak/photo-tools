<#
.SYNOPSIS
Rename DNG files to YYYYMMDD-event-NNNNN.dng.

.DESCRIPTION
phototools_rename_dng.ps1 (Windows PowerShell version of phototools_rename_dng.sh) renames DNG
files to YYYYMMDD-event-NNNNN.dng.

The event is normalized like phototools_import_photos.ps1 ("Detroit Riverwalk" ->
detroit-riverwalk). The date comes from DateTimeOriginal, or the file
modification date when that EXIF tag is absent. Serials continue after the
highest existing number for that date and event, so a name is never reused.
Matching Lightroom/Photoshop .xmp sidecars are renamed alongside.

    20261017-detroit-riverwalk-00001.dng

Requires exiftool:  winget install OliverBetz.ExifTool   (or run tools\phototools_prereqs.ps1)

Works with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Directory
The folder holding the DNG files to rename.

.PARAMETER EventName
Event name (required), e.g. "Detroit Riverwalk" -> detroit-riverwalk.

.PARAMETER DryRun
Show what would be renamed, change nothing. With more than 500 files it warns
that this can take several minutes and asks whether to continue (when run from
a console).

.PARAMETER Recurse
Recurse into subdirectories.

.PARAMETER VerboseLog
Verbose: show the settings and, for each file, where its date came from and why
it was skipped. (This is not the common -Verbose parameter.)

.EXAMPLE
phototools_rename_dng.ps1 -DryRun -EventName "Detroit Riverwalk" D:\Photos\20261017\DNG

.EXAMPLE
phototools_rename_dng.ps1 -EventName "Detroit Riverwalk" D:\Photos\20261017\DNG
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Directory,
    [string]$EventName,
    [switch]$DryRun,
    [switch]$Recurse,
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Continue'

function Show-Usage {
    [Console]::Error.WriteLine('Usage: phototools_rename_dng.ps1 [-DryRun] [-Recurse] [-VerboseLog] -EventName EVENT DIRECTORY')
    [Console]::Error.WriteLine('  -DryRun      dry run (show changes only)')
    [Console]::Error.WriteLine('  -Recurse     recurse into subdirectories')
    [Console]::Error.WriteLine('  -VerboseLog  verbose: show what is happening (default: off)')
    [Console]::Error.WriteLine('  -EventName   event name, e.g. "Detroit Riverwalk"')
    exit 1
}
function Stop-Script {
    param([string]$Message)
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}
function Write-VLog {
    param([string]$Message)
    if ($VerboseLog) { [Console]::Error.WriteLine("verbose: $Message") }
}

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
$nameComparer = if ($onWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$inv = [Globalization.CultureInfo]::InvariantCulture

if (-not $Directory) { Show-Usage }
if (-not $EventName) { Stop-Script 'an event name is required (-EventName EVENT).' }
$eventSlug = ($EventName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $eventSlug) { Stop-Script "event name '$EventName' has no usable letters or digits." }
if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { Stop-Script "'$Directory' is not a directory." }
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    Stop-Script "exiftool not found. Install it (e.g. 'winget install OliverBetz.ExifTool')."
}
$Directory = (Resolve-Path -LiteralPath $Directory).ProviderPath

# Run exiftool with its arguments in a UTF-8 argument file, so folder names with
# accented or non-Latin characters survive on any code page. Returns its output lines.
function Invoke-ExifTool {
    param([string[]]$ToolArgs)
    $argFile = [IO.Path]::GetTempFileName()
    $oldEncoding = $null
    try {
        [IO.File]::WriteAllLines($argFile, [string[]](@('-charset', 'filename=UTF8', '-charset', 'UTF8') + $ToolArgs),
                                 (New-Object System.Text.UTF8Encoding($false)))
        try {
            $oldEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch { $oldEncoding = $null }
        & exiftool -charset UTF8 -@ $argFile 2>$null
    } finally {
        if ($oldEncoding) { try { [Console]::OutputEncoding = $oldEncoding } catch { Write-Verbose 'could not restore console encoding' } }
        Remove-Item -LiteralPath $argFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-Ymd {
    param([string]$Text)
    return ($Text -cmatch '^[12][0-9]{3}[01][0-9][0-3][0-9]$')
}

# The next free serial for a date and event: one more than the highest existing one.
function Get-NextSerial {
    param([string]$Dir, [string]$Prefix)
    $max = 0
    $pattern = '^' + [regex]::Escape($Prefix) + '-([0-9]{5})\.dng$'
    foreach ($f in [IO.Directory]::EnumerateFiles($Dir)) {
        $m = [regex]::Match([IO.Path]::GetFileName($f), $pattern, 'IgnoreCase')
        if ($m.Success) {
            $n = [int]$m.Groups[1].Value
            if ($n -gt $max) { $max = $n }
        }
    }
    return $max + 1
}

# A dry run still reads every file's metadata, so warn before a big one.
# Asks first when run from a console; otherwise warns and carries on.
$dryRunWarnFiles = 500
function Confirm-LargeDryRun {
    param([int]$Count)
    if (-not $DryRun -or $Count -le $dryRunWarnFiles) { return }
    [Console]::Error.WriteLine("Warning: $Count files found. A dry run can take several minutes to complete.")
    if (-not [Console]::IsInputRedirected) {
        [Console]::Error.Write('Continue? [y/N] ')
        $reply = [Console]::In.ReadLine()
        if ($reply -notmatch '^(y|yes)$') {
            [Console]::Error.WriteLine('Cancelled - nothing was changed.')
            exit 0
        }
    }
}

Write-VLog ("directory: $Directory; event: $EventName -> $eventSlug; recurse: " + $(if ($Recurse) { 'yes' } else { 'no' }) +
            '; dry run: ' + $(if ($DryRun) { 'yes' } else { 'no' }))
if ($DryRun) {
    $searchOption = if ($Recurse) { [IO.SearchOption]::AllDirectories } else { [IO.SearchOption]::TopDirectoryOnly }
    $count = 0
    try {
        foreach ($f in [IO.Directory]::EnumerateFiles($Directory, '*', $searchOption)) {
            if ([IO.Path]::GetExtension($f) -ieq '.dng') { $count++ }
        }
    } catch { Write-Verbose "could not count files: $_" }
    Confirm-LargeDryRun $count
}
Write-VLog 'reading capture dates with exiftool...'

$renamed = 0; $skipped = 0; $failed = 0; $found = 0
$planned = New-Object 'System.Collections.Generic.HashSet[string]' $nameComparer   # names already claimed in this run

# ExifTool reports '-' for missing DateTimeOriginal; use the file date instead.
$toolArgs = @('-q', '-q', '-m', '-f')
if ($Recurse) { $toolArgs += '-r' }
$toolArgs += @('-ext', 'dng', '-d', '%Y%m%d',
               '-p', ('$Directory/$FileName' + "`t" + '$DateTimeOriginal'),
               $Directory)
$lines = @(Invoke-ExifTool $toolArgs | Where-Object { $_ })
[Array]::Sort($lines, [StringComparer]::Ordinal)

foreach ($line in $lines) {
    $parts = $line -split "`t"
    $src = $parts[0]
    $date = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    if (-not $src) { continue }
    $found++
    # exiftool prints forward slashes; use the platform's separator from here on.
    $src = [IO.Path]::GetFullPath($src)
    Write-VLog "found $src (DateTimeOriginal=$date)"
    if (-not (Test-Ymd $date)) {
        Write-VLog "$src has no DateTimeOriginal; using its modification date"
        try { $date = [IO.File]::GetLastWriteTime($src).ToString('yyyyMMdd', $inv) }
        catch {
            [Console]::Error.WriteLine("SKIP  $src (cannot read modification date)")
            $skipped++
            continue
        }
    }
    if (-not (Test-Ymd $date)) {
        [Console]::Error.WriteLine("SKIP  $src (invalid capture date '$date')")
        $skipped++
        continue
    }

    $dir = [IO.Path]::GetDirectoryName($src)
    $prefix = "$date-$eventSlug"
    $stem = [IO.Path]::GetFileNameWithoutExtension($src)

    # Carry along sidecars: IMG.xmp / IMG.XMP and IMG.dng.xmp styles
    $sidecars = @()
    $handled = New-Object 'System.Collections.Generic.HashSet[string]' $nameComparer
    foreach ($side in @((Join-Path $dir "$stem.xmp"), (Join-Path $dir "$stem.XMP"), "$src.xmp", "$src.XMP")) {
        if (-not $handled.Add($side)) { continue }
        if (-not (Test-Path -LiteralPath $side -PathType Leaf)) { continue }
        $sideExt = [IO.Path]::GetExtension($side).TrimStart('.')
        $qualified = $side.StartsWith("$src.", $(if ($onWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))
        $sidecars += [pscustomobject]@{ Path = $side; Ext = $sideExt; Qualified = $qualified }
    }

    if ($stem -cmatch ('^' + [regex]::Escape($prefix) + '-[0-9]{5}$')) {
        Write-VLog "$src is already named for $date and $eventSlug; skipping"
        $skipped++
        continue
    }

    $serial = Get-NextSerial $dir $prefix
    while ($true) {
        $new = '{0}-{1:D5}' -f $prefix, $serial
        $target = Join-Path $dir "$new.dng"
        $collision = $planned.Contains($target) -or (Test-Path -LiteralPath $target)
        foreach ($sidecar in $sidecars) {
            $sideTarget = if ($sidecar.Qualified) { "$target.$($sidecar.Ext)" } else { Join-Path $dir "$new.$($sidecar.Ext)" }
            if ($planned.Contains($sideTarget)) { $collision = $true }
            if ((Test-Path -LiteralPath $sideTarget) -and -not $nameComparer.Equals($sideTarget, $sidecar.Path)) { $collision = $true }
        }
        if (-not $collision) { break }
        Write-VLog "$new.dng (or one of its sidecars) is already taken; trying the next serial"
        $serial++
    }
    [void]$planned.Add($target)
    foreach ($sidecar in $sidecars) {
        $sideTarget = if ($sidecar.Qualified) { "$target.$($sidecar.Ext)" } else { Join-Path $dir "$new.$($sidecar.Ext)" }
        $sidecar | Add-Member -NotePropertyName Target -NotePropertyValue $sideTarget
        [void]$planned.Add($sideTarget)
    }

    if ($DryRun) {
        Write-Output "WOULD $src -> $new.dng"
    } else {
        try {
            [IO.File]::Move($src, $target)   # fails rather than overwrite, like mv -n
            Write-Output "OK    $src -> $new.dng"
            $renamed++
        } catch {
            [Console]::Error.WriteLine("FAIL  $src")
            $failed++
            continue
        }
    }

    foreach ($sidecar in $sidecars) {
        $sideName = [IO.Path]::GetFileName($sidecar.Path)
        $sideTargetName = [IO.Path]::GetFileName($sidecar.Target)
        if ($DryRun) {
            Write-Output "      + $sideName -> $sideTargetName"
        } else {
            try {
                [IO.File]::Move($sidecar.Path, $sidecar.Target)
                Write-Output "      + $sideName -> $sideTargetName"
            } catch {
                [Console]::Error.WriteLine("FAIL  $($sidecar.Path)")
                $failed++
            }
        }
    }
}

Write-VLog "examined $found file(s)"
Write-Output ''
if ($DryRun) {
    Write-Output 'Dry run complete - nothing was changed.'
} else {
    Write-Output "Renamed: $renamed   Skipped: $skipped   Failed: $failed"
    if ($failed -gt 0) { exit 2 }
}
exit 0
