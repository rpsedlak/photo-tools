<#
.SYNOPSIS
Rename Nikon NEF files to YYYYMMDDHHMMSS<subseconds>.NEF using the EXIF capture time.

.DESCRIPTION
phototools_rename_nef.ps1 (Windows PowerShell version of phototools_rename_nef.sh) renames Nikon NEF
files to YYYYMMDDHHMMSS<subseconds>.NEF using the capture time stored in EXIF.
With -Extension, other types (e.g. the JPG of a RAW+JPEG shot) are renamed the
same way, so a NEF and its JPG end up with the same name.

    20261017201845.NEF   <- 2026-10-17 20:18:45 (no subseconds available)
    2026101720184537.NEF <- 2026-10-17 20:18:45.37

Uses DateTimeOriginal + SubSecTimeOriginal. If two shots land on the exact same
subsecond (rare, but possible in fast bursts), a suffix _1, _2, ... is added.
Matching Lightroom/Photoshop .xmp sidecars are renamed alongside.

Requires exiftool:  winget install OliverBetz.ExifTool   (or run tools\phototools_prereqs.ps1)

Works with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Directory
The folder holding the files to rename.

.PARAMETER DryRun
Show what would be renamed, change nothing.

.PARAMETER Recurse
Recurse into subdirectories.

.PARAMETER Extension
Rename files with this extension instead of NEF, e.g. -Extension jpg
(matches upper and lower case; the extension's case is kept).

.EXAMPLE
phototools_rename_nef.ps1 D:\Photos\20261017\NEF

.EXAMPLE
phototools_rename_nef.ps1 -DryRun -Recurse -Extension jpg D:\Photos
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Directory,
    [switch]$DryRun,
    [switch]$Recurse,
    [string]$Extension = 'NEF'
)

$ErrorActionPreference = 'Continue'

function Show-Usage {
    [Console]::Error.WriteLine('Usage: phototools_rename_nef.ps1 [-DryRun] [-Recurse] [-Extension EXT] DIRECTORY')
    [Console]::Error.WriteLine('  -DryRun      dry run (show changes only)')
    [Console]::Error.WriteLine('  -Recurse     recurse into subdirectories')
    [Console]::Error.WriteLine('  -Extension   rename this file type instead of NEF (e.g. jpg)')
    exit 1
}

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
$nameComparer = if ($onWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }

if (-not $Directory) { Show-Usage }
$Extension = $Extension.TrimStart('.')
if ($Extension -notmatch '^[A-Za-z0-9]+$') {
    [Console]::Error.WriteLine("Error: -Extension takes a file extension such as jpg, got '$Extension'")
    exit 1
}
if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    [Console]::Error.WriteLine("Error: '$Directory' is not a directory")
    exit 1
}
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("Error: exiftool not found. Install it (e.g. 'winget install OliverBetz.ExifTool').")
    exit 1
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

$renamed = 0; $skipped = 0; $failed = 0
$planned = New-Object 'System.Collections.Generic.HashSet[string]' $nameComparer   # names already claimed in this run

# One exiftool call for the whole directory: path <TAB> datetime <TAB> subsec
# -f prints "-" for missing tags; -ext matches upper and lower case (.nef/.NEF).
$toolArgs = @('-q', '-q', '-m', '-f')
if ($Recurse) { $toolArgs += '-r' }
$toolArgs += @('-ext', $Extension, '-d', '%Y%m%d%H%M%S',
               '-p', ('$Directory/$FileName' + "`t" + '$DateTimeOriginal' + "`t" + '$SubSecTimeOriginal'),
               $Directory)
$lines = @(Invoke-ExifTool $toolArgs | Where-Object { $_ })
[Array]::Sort($lines, [StringComparer]::Ordinal)

foreach ($line in $lines) {
    $parts = $line -split "`t"
    $src = $parts[0]
    $dto = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $subsec = if ($parts.Count -gt 2) { $parts[2] } else { '' }
    if (-not $src) { continue }
    # exiftool prints forward slashes; use the platform's separator from here on.
    $src = [IO.Path]::GetFullPath($src)
    $dir = [IO.Path]::GetDirectoryName($src)
    $file = [IO.Path]::GetFileName($src)
    $ext = [IO.Path]::GetExtension($file).TrimStart('.')
    $stem = [IO.Path]::GetFileNameWithoutExtension($file)

    if (-not $dto -or $dto -eq '-') {
        Write-Output "SKIP  $src (no DateTimeOriginal in EXIF)"
        $skipped++
        continue
    }

    $subsec = $subsec -replace '[^0-9]', ''   # strip spaces / "-" placeholder
    $base = "$dto$subsec"

    # Pick a free target name
    $new = $base
    $n = 0
    while ($true) {
        $target = Join-Path $dir "$new.$ext"
        if ($nameComparer.Equals($target, $src)) { break }   # already correctly named
        if (-not $planned.Contains($target) -and -not (Test-Path -LiteralPath $target)) { break }
        $n++
        $new = "${base}_$n"
    }

    if ($nameComparer.Equals($target, $src)) {
        $skipped++
        continue
    }
    [void]$planned.Add($target)

    if ($DryRun) {
        Write-Output "WOULD $src -> $new.$ext"
    } else {
        try {
            [IO.File]::Move($src, $target)   # fails rather than overwrite, like mv -n
            Write-Output "OK    $src -> $new.$ext"
            $renamed++
        } catch {
            Write-Output "FAIL  $src"
            $failed++
            continue
        }
    }

    # Carry along sidecars: IMG.xmp / IMG.XMP and IMG.NEF.xmp styles
    $handled = New-Object 'System.Collections.Generic.HashSet[string]' $nameComparer
    foreach ($side in @((Join-Path $dir "$stem.xmp"), (Join-Path $dir "$stem.XMP"), "$src.xmp", "$src.XMP")) {
        if (-not $handled.Add($side)) { continue }
        if (-not (Test-Path -LiteralPath $side -PathType Leaf)) { continue }
        $sideExt = [IO.Path]::GetExtension($side).TrimStart('.')
        if ($side.StartsWith("$src.", [StringComparison]::Ordinal) -or ($onWindows -and $side.StartsWith("$src.", [StringComparison]::OrdinalIgnoreCase))) {
            $sideTarget = "$target.$sideExt"
        } else {
            $sideTarget = Join-Path $dir "$new.$sideExt"
        }
        $sideName = [IO.Path]::GetFileName($side)
        $sideTargetName = [IO.Path]::GetFileName($sideTarget)
        if ($DryRun) {
            Write-Output "      + $sideName -> $sideTargetName"
        } else {
            try {
                [IO.File]::Move($side, $sideTarget)
                Write-Output "      + $sideName -> $sideTargetName"
            } catch {
                Write-Verbose "sidecar $side was not renamed: $_"
            }
        }
    }
}

Write-Output ''
if ($DryRun) {
    Write-Output 'Dry run complete - nothing was changed.'
} else {
    Write-Output "Renamed: $renamed   Skipped: $skipped   Failed: $failed"
    if ($failed -gt 0) { exit 2 }
}
if ($failed -gt 0) { exit 1 }
exit 0
