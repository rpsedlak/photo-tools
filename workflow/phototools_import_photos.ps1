<#
.SYNOPSIS
Import photos from one SD card onto a destination disk (Windows PowerShell version of phototools_import_photos.sh).

.DESCRIPTION
phototools_import_photos.ps1 imports photos from one SD card in five steps:

  1. COPY    Every file in the card's DCIM folder is copied (never moved -
             the card is left untouched) into a folder for its capture date,
             then a subfolder for its extension, and each copy is verified:
                 <destination>\20261017\NEF\
                                       \JPG\
                                       \MOV\
                 <destination>\20261018\NEF\ ...
             The date comes from the photo's EXIF capture time
             (DateTimeOriginal), or the file's timestamp when there is none.
             Each of those date folders also gets an empty prod\ folder
             (left as-is if it already exists).
             RAW+JPEG shots (DSC_0001.NEF + DSC_0001.JPG) are both copied,
             each to its own extension folder.
  2. RENAME  The newly imported NEFs and JPGs are renamed to their capture
             time, YYYYMMDDHHMMSS<subsec>.NEF / .JPG, by phototools_rename_nef.ps1 (same
             folder as this script), so they sort by time and the two files
             of a RAW+JPEG shot share a name:
                 20261017\NEF\2026101720184537.NEF
                 20261017\JPG\2026101720184537.JPG
             Other types (MOV, ...) keep their camera names.
  3. DNG     Those NEFs are converted with Adobe DNG Converter into the
             date folder's DNG\, named <YYYYMMDD>-<event>-<nnnnn>.dng in
             capture order. Only NEFs are converted: for a RAW+JPEG shot the
             DNG always comes from the NEF, and JPEG-only shots get no DNG.
  4. COPYRIGHT
             With an owner set (-CopyrightOwner, or PHOTO_COPYRIGHT_OWNER),
             each new DNG gets "(c) <year> <owner>" (with the (c) sign) as its
             copyright and <owner> as its creator (EXIF, XMP, and IPTC if
             present), with <year> taken from that photo's capture date.
             NEFs are never modified.
  5. COMPRESS
             Once a date's NEFs are all converted and filed, its NEF\ folder
             is zipped into <destination>\20261017\NEF.zip, the zip is tested,
             and the NEF\ folder is removed. Turn this off with -NoCompress or
             PHOTO_COMPRESS_NEF=0. Not done with -SkipDng (no DNGs were made),
             or while any NEF of that date still waits for a retry. If a later
             card adds NEFs to a date that already has NEF.zip, the zip is
             unpacked first (so duplicates are still caught), then re-zipped.

Several cards for the same date and event
  Import them one after another. <nnnnn> continues from the highest number
  already in that date's DNG\ for that event, so the second card's DNGs
  carry on (...-00143, ...-00144, ...) and a DNG name is never reused or
  overwritten. Two events on the same day each have their own sequence.

No duplicates
  * A manifest (.photo-import-manifest.tsv on the destination) remembers every
    file imported (name + size + EXIF capture time), so re-inserting a card -
    or importing the backup card from the camera's second slot - copies
    nothing. The manifest has the same format as the Mac version's, so one
    manifest can be shared between both.
  * Before converting, each new NEF is compared byte-for-byte with the NEFs
    already in that date folder; an identical photo is dropped, so it can
    never get a second DNG. New JPGs are checked the same way.

The card is the drive that has a DCIM folder at its root (other than the
destination); name it with -Source if there is none or more than one. -Source
can be a drive root such as E:\ or any folder.

Exit codes: 0 = done, 2 = done but some files had problems (see the FAIL
lines; the card is not ejected), 1 = error (nothing imported).

Requires: exiftool (winget install OliverBetz.ExifTool), Adobe DNG Converter
(free, from Adobe) unless -SkipDng, and phototools_rename_nef.ps1 next to this script.

Works with Windows PowerShell 5.1 and PowerShell 7+.

Environment overrides:
  PHOTO_IMPORT_DEST      destination root (same as -Destination; the
                         parameter overrides it)
  PHOTO_COPYRIGHT_OWNER  default for -CopyrightOwner; set it once, e.g.
                         setx PHOTO_COPYRIGHT_OWNER "Richard Sedlak"
  PHOTO_COMPRESS_NEF     set to 0 (or no/false/off/n) to stop compressing NEF\
                         folders after import (same as -NoCompress)
  DNG_CONVERTER          path to the converter program (default:
                         C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe,
                         else the Program Files (x86) equivalent)
  DNG_OPTS               converter options (default: "-c -p1" = lossless
                         compressed, medium preview). See Adobe's DNG Converter
                         command-line notes.

.PARAMETER EventName
Event name (required). "Detroit Riverwalk" -> detroit-riverwalk

.PARAMETER CopyrightOwner
Copyright owner written into each new DNG, e.g. "Richard Sedlak"
(default: $env:PHOTO_COPYRIGHT_OWNER; no copyright if neither is set).

.PARAMETER Source
The card: a drive root such as E:\ or any folder (default: the drive that has
a DCIM folder at its root).

.PARAMETER Destination
Destination root (required unless $env:PHOTO_IMPORT_DEST is set).

.PARAMETER Date
YYYYMMDD: put everything in this one date folder instead of sorting by each
file's capture date.

.PARAMETER VerifyBytes
Verify copies byte-for-byte (default: size check).

.PARAMETER SkipDng
Copy and rename only; skip DNG conversion (and NEF compression).

.PARAMETER NoCompress
Do not zip the NEF\ folders afterwards (default: zip them;
PHOTO_COMPRESS_NEF=0 turns it off too).

.PARAMETER Force
Ignore the manifest and copy everything again (identical photos are still
never converted twice).

.PARAMETER Eject
Eject the card when finished (only works when the source is a drive root).

.PARAMETER DryRun
Show what would happen, change nothing.

.EXAMPLE
.\phototools_import_photos.ps1 -EventName "Detroit Riverwalk" -Destination D:\Photos -CopyrightOwner "Richard Sedlak"

.EXAMPLE
.\phototools_import_photos.ps1 -EventName wedding -Destination D:\Photos -Source E:\ -Eject

.EXAMPLE
.\phototools_import_photos.ps1 -EventName wedding -Destination D:\Photos -DryRun

.NOTES
The DNG conversion and copyright steps need the real Adobe DNG Converter and
exiftool on PATH. Output goes to the console; a line is printed at every 10%
instead of a rewritten status line when the output is redirected to a file.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$EventName,
    [string]$CopyrightOwner = $env:PHOTO_COPYRIGHT_OWNER,
    [string]$Source,
    [string]$Destination = $env:PHOTO_IMPORT_DEST,
    [string]$Date,
    [switch]$VerifyBytes,
    [switch]$SkipDng,
    [switch]$NoCompress,
    [switch]$Force,
    [switch]$Eject,
    [switch]$DryRun
)

# Native commands (exiftool) may write to stderr; that must never become a terminating error in 5.1.
$ErrorActionPreference = 'Continue'

# ---------- settings ----------------------------------------------------------
$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
$nameComparer = if ($onWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$nameCompare = if ($onWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$sep = [string][IO.Path]::DirectorySeparatorChar
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$inv = [Globalization.CultureInfo]::InvariantCulture
$latin1 = [Text.Encoding]::GetEncoding(28591)   # 1:1 byte <-> char, for fast chunk comparison
$copySign = [string][char]0x00A9
$RenameScript = Join-Path $PSScriptRoot 'phototools_rename_nef.ps1'

$DngConverter = $env:DNG_CONVERTER
if (-not $DngConverter) {
    $DngConverter = 'C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe'
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        $candidate = [IO.Path]::Combine($pf, 'Adobe', 'Adobe DNG Converter', 'Adobe DNG Converter.exe')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $DngConverter = $candidate; break }
    }
}
$DngOpts = if ($env:DNG_OPTS) { $env:DNG_OPTS } else { '-c -p1' }
$DngBatch = 100                  # NEFs per converter launch
$DngCmdLimit = 30000             # characters per converter command line

$CompressNef = $true
if (@('0', 'no', 'false', 'off', 'n') -contains ([string]$env:PHOTO_COMPRESS_NEF).ToLowerInvariant()) { $CompressNef = $false }
if ($NoCompress) { $CompressNef = $false }

$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:ProgTty = -not [Console]::IsOutputRedirected
$script:ProgStep = -1
$script:ProgLen = 0
$script:ProgLast = -1000
$script:ExifExit = 0
$script:ConvProc = $null
$script:Finished = $false
$script:Failed = 0
$script:ConvFailed = 0
$script:Converted = 0
$script:Dupes = 0
$script:JpgDupes = 0
$script:NefZipped = 0

try { Add-Type -AssemblyName System.IO.Compression } catch { Write-Verbose 'System.IO.Compression not loaded' }
try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { Write-Verbose 'System.IO.Compression.FileSystem not loaded' }

# ---------- helpers -----------------------------------------------------------
function Write-Line { param([string]$Text) Write-Host $Text }
function Write-Err { param([string]$Text) [Console]::Error.WriteLine($Text) }

function Stop-Import {
    param([string]$Message)
    $script:Finished = $true
    Write-Err "Error: $Message"
    exit 1
}

function Get-IntDiv { param([long]$A, [long]$B) [long][Math]::Floor($A / $B) }

function Test-Ymd { param([string]$Text) $Text -match '^[12][0-9]{3}[01][0-9][0-3][0-9]$' }

function Get-ExtOf {
    param([string]$Path)
    $e = [IO.Path]::GetExtension([IO.Path]::GetFileName($Path)).TrimStart('.')
    if ($e) { $e.ToUpperInvariant() } else { 'OTHER' }
}

function Get-CleanPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char]'\', [char]'/') }
    $full
}

# ---------- progress display --------------------------------------------------
# On a terminal one status line is rewritten in place; when the output goes to
# a file or pipe, a line is printed at every 10% instead.
function Show-Status {
    param([long]$Percent, [string]$Text)
    if ($script:ProgTty) {
        $now = $script:Clock.ElapsedMilliseconds
        if (($now - $script:ProgLast) -lt 100) { return }
        $script:ProgLast = $now
        $width = 0
        try { $width = [Console]::WindowWidth } catch { $width = 0 }
        if ($width -gt 1 -and $Text.Length -ge $width) { $Text = $Text.Substring(0, $width - 1) }
        $pad = ''
        if ($script:ProgLen -gt $Text.Length) { $pad = ' ' * ($script:ProgLen - $Text.Length) }
        Write-Host ("`r" + $Text + $pad) -NoNewline
        $script:ProgLen = $Text.Length
    } else {
        $step = [int](Get-IntDiv ([Math]::Min([Math]::Max($Percent, 0), 100)) 10)
        if ($step -ne $script:ProgStep) {
            $script:ProgStep = $step
            Write-Host $Text
        }
    }
}

function Clear-Status {     # clear the status line before normal output resumes
    if ($script:ProgTty -and $script:ProgLen -gt 0) {
        Write-Host ("`r" + (' ' * $script:ProgLen) + "`r") -NoNewline
    }
    $script:ProgLen = 0
    $script:ProgStep = -1
}

function Get-ElapsedSec { [long][Math]::Floor($script:Clock.Elapsed.TotalSeconds) }

function Format-Hms {
    param([long]$Seconds)
    if ($Seconds -ge 3600) {
        '{0}h{1:D2}m' -f (Get-IntDiv $Seconds 3600), (Get-IntDiv ($Seconds % 3600) 60)
    } else {
        '{0}m{1:D2}s' -f (Get-IntDiv $Seconds 60), ($Seconds % 60)
    }
}

function Format-SizeH {
    param([long]$Bytes)
    if ($Bytes -ge 1073741824) {
        '{0}.{1} GB' -f (Get-IntDiv $Bytes 1073741824), (Get-IntDiv (($Bytes % 1073741824) * 10) 1073741824)
    } else {
        '{0} MB' -f (Get-IntDiv $Bytes 1048576)
    }
}

function Get-Timing {       # "1m02s, ~3m10s left"
    param([long]$Start, [long]$Done, [long]$Total)
    $el = (Get-ElapsedSec) - $Start
    $text = Format-Hms $el
    if ($Done -gt 0 -and $Done -lt $Total -and $el -ge 2) {
        $text += ', ~' + (Format-Hms (Get-IntDiv ($el * ($Total - $Done)) $Done)) + ' left'
    }
    $text
}

# ---------- file helpers ------------------------------------------------------
function Write-ArgFile {    # UTF-8 without BOM, LF newlines
    param([string]$Path, [string[]]$Lines)
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $utf8NoBom)
}

# Run exiftool with its arguments in a UTF-8 argument file, so folder names and
# owner names with accented or non-Latin characters survive on any code page.
# -CommonArgs go in a second argument file after -common_args (they apply to every
# -execute section). Emits exiftool's output lines; its exit code is in $script:ExifExit.
function Invoke-ExifTool {
    param([string[]]$ToolArgs, [string[]]$CommonArgs)
    $charsetArgs = @('-charset', 'filename=UTF8', '-charset', 'UTF8')
    $argFile = [IO.Path]::GetTempFileName()
    $commonFile = $null
    try {
        Write-ArgFile $argFile ($charsetArgs + $ToolArgs)
        $cmd = @('-charset', 'UTF8', '-@', $argFile)
        if ($CommonArgs) {
            $commonFile = [IO.Path]::GetTempFileName()
            Write-ArgFile $commonFile ($charsetArgs + $CommonArgs)
            $cmd += @('-common_args', '-charset', 'UTF8', '-@', $commonFile)
        }
        & exiftool @cmd 2>$null
        $script:ExifExit = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $argFile -Force -ErrorAction SilentlyContinue
        if ($commonFile) { Remove-Item -LiteralPath $commonFile -Force -ErrorAction SilentlyContinue }
    }
}

function Read-Full {        # fill the buffer from the stream; returns the byte count (less only at the end)
    param([IO.Stream]$Stream, [byte[]]$Buffer)
    $got = 0
    while ($got -lt $Buffer.Length) {
        $n = $Stream.Read($Buffer, $got, $Buffer.Length - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    $got
}

function Compare-Stream {   # byte-for-byte, 1 MB at a time
    param([IO.Stream]$A, [IO.Stream]$B)
    $bufA = New-Object byte[] 1048576
    $bufB = New-Object byte[] 1048576
    while ($true) {
        $na = Read-Full $A $bufA
        $nb = Read-Full $B $bufB
        if ($na -ne $nb) { return $false }
        if ($na -eq 0) { return $true }
        if (-not [string]::Equals($latin1.GetString($bufA, 0, $na), $latin1.GetString($bufB, 0, $nb), [StringComparison]::Ordinal)) { return $false }
    }
}

function Compare-FileBytes {    # size check first, then the contents; like cmp -s
    param([string]$PathA, [string]$PathB)
    $sa = $null; $sb = $null
    try {
        if ((New-Object IO.FileInfo $PathA).Length -ne (New-Object IO.FileInfo $PathB).Length) { return $false }
        $sa = New-Object IO.FileStream($PathA, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sb = New-Object IO.FileStream($PathB, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return (Compare-Stream $sa $sb)
    } catch {
        return $false
    } finally {
        if ($sa) { $sa.Dispose() }
        if ($sb) { $sb.Dispose() }
    }
}

# All files under a folder, skipping hidden files and folders (names starting with '.').
function Get-ScanFiles {
    param([string]$Root)
    $result = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::GetFiles($dir)) {
                if (-not [IO.Path]::GetFileName($f).StartsWith('.')) { $result.Add($f) }
            }
            foreach ($d in [IO.Directory]::GetDirectories($dir)) {
                if ([IO.Path]::GetFileName($d).StartsWith('.')) { continue }
                if (([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($d)
            }
        } catch {
            Write-Err "WARN  cannot read folder $dir"
        }
    }
    $all = $result.ToArray()
    [Array]::Sort($all, [StringComparer]::Ordinal)
    $all
}

# Files directly in a folder with this extension (any case), no hidden files, sorted by name.
function Get-IncomingFiles {
    param([string]$Dir, [string]$Ext)
    if (-not [IO.Directory]::Exists($Dir)) { return @() }
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in [IO.Directory]::GetFiles($Dir)) {
        $n = [IO.Path]::GetFileName($f)
        if ($n.StartsWith('.')) { continue }
        if ([IO.Path]::GetExtension($n).Equals(".$Ext", [StringComparison]::OrdinalIgnoreCase)) { $result.Add($f) }
    }
    $all = $result.ToArray()
    [Array]::Sort($all, [StringComparer]::Ordinal)
    $all
}

function Remove-EmptyDir {
    param([string]$Path)
    try { if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path) } } catch { Write-Verbose "$Path is not empty" }
}

function Remove-FileQuiet {
    param([string]$Path)
    try { [IO.File]::Delete($Path) } catch { Write-Verbose "could not delete ${Path}: $_" }
}

function Remove-Tree {
    param([string]$Path)
    try { if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path, $true) } } catch { Write-Verbose "could not remove ${Path}: $_" }
}

function Test-PathExists { param([string]$Path) [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path) }

function Add-ManifestKey {
    param([string]$Key)
    if ($script:ManifestSet.Add($Key)) {
        [IO.File]::AppendAllText($script:Manifest, $Key + "`n", $utf8NoBom)
    }
}

# ---------- per-date steps ----------------------------------------------------
function Get-NextSerial {   # highest existing NNNNN for the prefix, plus one
    param([string]$Dir, [string]$Prefix)
    $max = 0
    if ([IO.Directory]::Exists($Dir)) {
        $rx = '^' + [regex]::Escape($Prefix) + '-([0-9]{5})\.dng$'
        foreach ($f in [IO.Directory]::GetFiles($Dir)) {
            $m = [regex]::Match([IO.Path]::GetFileName($f), $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $n = [int]$m.Groups[1].Value
                if ($n -gt $max) { $max = $n }
            }
        }
    }
    $max + 1
}

# Move a NEF/JPG (and any sidecar) out of .incoming into its final folder.
function Move-ToFinal {
    param([string]$Src, [string]$FinalDir, $Names)
    $base = [IO.Path]::GetFileName($Src)
    $stem = [IO.Path]::GetFileNameWithoutExtension($Src)
    $ext = [IO.Path]::GetExtension($Src)
    $target = Join-Path $FinalDir $base
    $n = 0
    while (Test-PathExists $target) { $n++; $target = Join-Path $FinalDir "${stem}_$n$ext" }
    try {
        [IO.File]::Move($Src, $target)     # fails rather than overwrite, like mv -n
        $Names.Add([IO.Path]::GetFileName($target))
    } catch {
        Write-Err "FAIL  could not file $Src"
        return
    }
    $srcStem = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Src), $stem)
    foreach ($side in @("$Src.xmp", "$Src.XMP", "$srcStem.xmp", "$srcStem.XMP")) {
        if (-not [IO.File]::Exists($side)) { continue }
        $sideTarget = Join-Path $FinalDir ([IO.Path]::GetFileName($side))
        if (Test-PathExists $sideTarget) { continue }
        try { [IO.File]::Move($side, $sideTarget) } catch { Write-Verbose "sidecar $side was not moved: $_" }
    }
}

# Same photo => same capture-time name (rename_nef adds _1, _2 on clashes).
function Test-Duplicate {
    param([string]$File, [string]$FinalDir, $Names)
    $stem = [IO.Path]::GetFileNameWithoutExtension($File)
    $root = [regex]::Replace($stem, '_[1-9][0-9]{0,2}$', '')
    $r1 = $root + '.'
    $r2 = $root + '_'
    foreach ($name in $Names) {
        $hit = $false
        if ($name.StartsWith($r1, $nameCompare)) {
            $hit = $true
        } elseif ($name.StartsWith($r2, $nameCompare) -and $name.Length -gt $r2.Length) {
            $c = $name[$r2.Length]
            if ($c -ge [char]'1' -and $c -le [char]'9' -and $name.IndexOf('.', $r2.Length + 1) -ge 0) { $hit = $true }
        }
        if ($hit -and (Compare-FileBytes $File (Join-Path $FinalDir $name))) { return $true }
    }
    return $false
}

function Get-FolderNames {  # names of the files directly in a folder
    param([string]$Dir)
    $names = New-Object 'System.Collections.Generic.List[string]'
    if ([IO.Directory]::Exists($Dir)) {
        foreach ($f in [IO.Directory]::GetFiles($Dir)) { $names.Add([IO.Path]::GetFileName($f)) }
    }
    # a comma keeps the (possibly empty) list from being unrolled
    , $names
}

# Run phototools_rename_nef.ps1 in-process and turn its output into progress.
function Invoke-Rename {
    param([string]$Inc, [int]$Total, [string]$Ext)
    $renameArgs = @{ Directory = $Inc }
    if ($Ext) { $renameArgs.Extension = $Ext }
    $state = @{ N = 0 }
    & $RenameScript @renameArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line.StartsWith('OK ', [StringComparison]::Ordinal)) {
            $state.N++
            Show-Status (Get-IntDiv ($state.N * 100) $Total) "          renaming... $($state.N)/$Total"
        } elseif ($line.StartsWith('FAIL', [StringComparison]::Ordinal) -or $line.StartsWith('SKIP', [StringComparison]::Ordinal)) {
            Clear-Status
            Write-Err "          $line"
        } elseif ($line.StartsWith('Renamed:', [StringComparison]::Ordinal)) {
            Clear-Status
            Write-Line "          $line"
        }
    }
    Clear-Status
}

# Unpack an earlier NEF.zip so new NEFs are checked against it (never overwrites, like unzip -n).
function Restore-NefZip {
    param([string]$Day)
    $dir = Join-Path $script:DestRoot $Day
    $zipPath = Join-Path $dir 'NEF.zip'
    if (-not ($script:CompressNef -and [IO.File]::Exists($zipPath))) { return $true }
    Write-Line "${Day}: unpacking NEF.zip..."
    $zip = $null
    try {
        $dirFull = (Get-CleanPath $dir) + $sep
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            $dest = [IO.Path]::GetFullPath((Join-Path $dir ($e.FullName.Replace('/', $sep))))
            if (-not $dest.StartsWith($dirFull, [StringComparison]::Ordinal)) { throw "unsafe entry name $($e.FullName)" }
            if ([IO.File]::Exists($dest)) { continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $false)
        }
        return $true
    } catch {
        Write-Err "FAIL  could not unpack $Day/NEF.zip"
        return $false
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

# Zip NEF\ into NEF.zip, test the zip, then remove NEF\.
function Compress-Nef {
    param([string]$Day)
    $dir = Join-Path $script:DestRoot $Day
    $nef = Join-Path $dir 'NEF'
    $tmp = Join-Path $dir '.NEF.tmp.zip'
    if (-not [IO.Directory]::Exists($nef)) { return }
    if ([IO.Directory]::Exists((Join-Path $nef '.incoming'))) { return }   # NEFs still waiting
    $files = @([IO.Directory]::GetFiles($nef, '*', [IO.SearchOption]::AllDirectories))
    if ($files.Count -eq 0) { return }
    Write-Line "${Day}: compressing NEF/ to NEF.zip..."
    try {
        [IO.File]::Delete($tmp)
        $fs = New-Object IO.FileStream($tmp, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $zip = $null
        try {
            $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            foreach ($f in $files) {
                $rel = $f.Substring($nef.Length + 1).Replace($sep, '/')
                $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f, "NEF/$rel", [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally {
            if ($zip) { $zip.Dispose() }
            $fs.Dispose()
        }

        # Test: reopen, check the entry count, and compare every entry with its source file.
        $zr = [IO.Compression.ZipFile]::OpenRead($tmp)
        try {
            if ($zr.Entries.Count -ne $files.Count) { throw 'entry count differs' }
            foreach ($e in $zr.Entries) {
                $srcFile = Join-Path $dir ($e.FullName.Replace('/', $sep))
                $es = $e.Open()
                $ss = $null
                try {
                    $ss = New-Object IO.FileStream($srcFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    if (-not (Compare-Stream $es $ss)) { throw "entry $($e.FullName) differs" }
                } finally {
                    $es.Dispose()
                    if ($ss) { $ss.Dispose() }
                }
            }
        } finally {
            $zr.Dispose()
        }

        Move-Item -LiteralPath $tmp -Destination (Join-Path $dir 'NEF.zip') -Force -ErrorAction Stop
        Remove-Tree $nef
        $script:NefZipped++
    } catch {
        Write-Verbose "compress failed: $_"
        try { [IO.File]::Delete($tmp) } catch { Write-Verbose 'could not remove the temporary zip' }
        Write-Err "WARN  could not compress $Day/NEF (left as is)"
    }
}

# Quote one argument for a Windows command line.
function ConvertTo-QuotedArg {
    param([string]$Text)
    $q = [regex]::Replace($Text, '(\\*)"', '$1$1\"')
    $q = [regex]::Replace($q, '(\\+)$', '$1$1')
    '"' + $q + '"'
}

function Get-DngCount {
    param([string]$Dir)
    $n = 0
    foreach ($f in [IO.Directory]::GetFiles($Dir)) {
        if ([IO.Path]::GetExtension($f).Equals('.dng', [StringComparison]::OrdinalIgnoreCase)) { $n++ }
    }
    $n
}

# Adobe DNG Converter is a GUI program, so '&' would not wait for it: start it, then poll.
function Invoke-DngConvert {
    param([string[]]$Files, [string]$OutDir, [long]$Start)
    $total = $Files.Count
    $head = $DngOpts + ' -d ' + (ConvertTo-QuotedArg $OutDir)
    $j = 0
    while ($j -lt $total) {
        $cmdLine = New-Object Text.StringBuilder $head
        $count = 0
        while (($j + $count) -lt $total -and $count -lt $DngBatch) {
            $quoted = ConvertTo-QuotedArg $Files[$j + $count]
            if ($count -gt 0 -and ($cmdLine.Length + 1 + $quoted.Length) -gt $DngCmdLimit) { break }
            $null = $cmdLine.Append(' ').Append($quoted)
            $count++
        }
        $startArgs = @{ FilePath = $DngConverter; ArgumentList = $cmdLine.ToString(); PassThru = $true; ErrorAction = 'Stop' }
        if ($onWindows) { $startArgs.WindowStyle = 'Hidden' }
        try {
            $proc = Start-Process @startArgs
        } catch {
            Write-Err "FAIL  could not start the DNG converter: $($_.Exception.Message)"
            return
        }
        $script:ConvProc = $proc
        $null = $proc.Handle     # keep the handle so ExitCode is available
        while (-not $proc.HasExited) {
            $made = Get-DngCount $OutDir
            Show-Status (Get-IntDiv ($made * 100) $total) "          converting... $made/$total  $(Get-Timing $Start $made $total)"
            Start-Sleep -Seconds 1
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
        $script:ConvProc = $null
        if ($code -ne 0) {
            Clear-Status
            Write-Err "WARN  the DNG converter exited with code $code"
        }
        $j += $count
    }
}

function Invoke-JpgStep {   # rename new JPGs to capture time and file them in JPG\
    param([string]$Day)
    $jd = Join-Path (Join-Path $script:DestRoot $Day) 'JPG'
    $inc = Join-Path $jd '.incoming'
    $jpgs = @(Get-IncomingFiles $inc 'jpg')
    if ($jpgs.Count -eq 0) { Remove-EmptyDir $inc; return }

    Write-Line ''
    Write-Line "${Day}: renaming $($jpgs.Count) JPG(s) to capture time..."
    Invoke-Rename $inc $jpgs.Count 'jpg'

    $names = Get-FolderNames $jd
    foreach ($f in @(Get-IncomingFiles $inc 'jpg')) {
        if (Test-Duplicate $f $jd $names) {
            Write-Line "          duplicate of an existing photo, skipped: $([IO.Path]::GetFileName($f))"
            [IO.File]::Delete($f)
            $script:JpgDupes++
        } else {
            Move-ToFinal $f $jd $names
        }
    }
    Remove-EmptyDir $inc
}

function Invoke-DateStep {  # rename, drop duplicates, convert, write copyright, file
    param([string]$Day)
    $nd = [IO.Path]::Combine($script:DestRoot, $Day, 'NEF')
    $inc = Join-Path $nd '.incoming'
    $dd = [IO.Path]::Combine($script:DestRoot, $Day, 'DNG')
    $din = Join-Path $dd '.incoming'
    $eventFile = Join-Path $inc '.event'
    $nefs = @(Get-IncomingFiles $inc 'nef')
    if ($nefs.Count -eq 0) {
        Remove-FileQuiet $eventFile; Remove-EmptyDir $inc
        return
    }

    if (-not (Restore-NefZip $Day)) { $script:Failed++; return }

    $ev = $script:EventSlug
    if ([IO.File]::Exists($eventFile)) {
        $first = @([IO.File]::ReadAllLines($eventFile))
        if ($first.Count -gt 0 -and $first[0].Trim()) { $ev = $first[0].Trim() }
    }

    Write-Line ''
    Write-Line "${Day}: renaming $($nefs.Count) NEF(s) to capture time..."
    Invoke-Rename $inc $nefs.Count ''

    # Drop any NEF that is byte-identical to one already imported.
    $names = Get-FolderNames $nd
    foreach ($f in @(Get-IncomingFiles $inc 'nef')) {
        if (Test-Duplicate $f $nd $names) {
            Write-Line "          duplicate of an existing photo, skipped: $([IO.Path]::GetFileName($f))"
            [IO.File]::Delete($f)
            $script:Dupes++
        }
    }
    $nefs = @(Get-IncomingFiles $inc 'nef')        # sorted = capture order after renaming
    if ($nefs.Count -eq 0) {
        Remove-FileQuiet $eventFile; Remove-EmptyDir $inc
        return
    }

    if ($SkipDng) {
        foreach ($f in $nefs) { Move-ToFinal $f $nd $names }
    } else {
        Write-Line "${Day}: converting $($nefs.Count) NEF(s) to DNG ($ev)..."
        Remove-Tree $din
        try { $null = [IO.Directory]::CreateDirectory($din) } catch { Stop-Import "cannot create $din" }
        $t0 = Get-ElapsedSec
        Invoke-DngConvert $nefs $din $t0
        Clear-Status
        Write-Line "          converted in $(Format-Hms ((Get-ElapsedSec) - $t0))"

        $dates = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        $dateArgs = @('-q', '-q', '-m', '-f', '-ext', 'nef', '-d', '%Y%m%d', '-p', ('$FileName' + "`t" + '$DateTimeOriginal'), $inc)
        foreach ($line in @(Invoke-ExifTool $dateArgs)) {
            $p = ([string]$line).Split("`t")
            if ($p.Count -ge 2 -and $p[0]) { $dates[$p[0]] = $p[1] }
        }

        # Copyright goes in before filing, so a failure leaves the NEFs to retry.
        $rightsOk = $true
        if ($CopyrightOwner) {
            $rightsArgs = New-Object 'System.Collections.Generic.List[string]'
            $rightsCount = 0
            foreach ($f in $nefs) {
                $base = [IO.Path]::GetFileName($f)
                $stem = [IO.Path]::GetFileNameWithoutExtension($f)
                foreach ($c in @((Join-Path $din "$stem.dng"), (Join-Path $din "$stem.DNG"))) {
                    if (-not [IO.File]::Exists($c)) { continue }
                    $dt = ''
                    if ($dates.ContainsKey($base)) { $dt = $dates[$base] }
                    if (-not (Test-Ymd $dt)) { $dt = $Day }
                    if ($rightsArgs.Count -gt 0) { $rightsArgs.Add('-execute') }
                    $rightsArgs.Add('-MWG:Copyright=' + $copySign + ' ' + $dt.Substring(0, 4) + ' ' + $CopyrightOwner)
                    $rightsArgs.Add($c)
                    $rightsCount++
                    break   # on a case-insensitive disk .dng and .DNG are the same file
                }
            }
            if ($rightsCount -gt 0) {
                Write-Line "${Day}: writing copyright ($CopyrightOwner)..."
                # -echo3 prints one line as each file is finished, for the status line.
                $common = @('-q', '-q', '-m', '-overwrite_original', "-MWG:Creator=$CopyrightOwner", '-XMP-xmpRights:Marked=True', '-echo3', '.')
                $state = @{ N = 0 }
                Invoke-ExifTool $rightsArgs.ToArray() $common | ForEach-Object {
                    $state.N++
                    Show-Status (Get-IntDiv ($state.N * 100) $rightsCount) "          writing copyright... $($state.N)/$rightsCount"
                }
                if ($script:ExifExit -ne 0) { $rightsOk = $false }
                Clear-Status
            }
            if (-not $rightsOk) { Write-Err "FAIL  could not write copyright to $Day's DNGs (re-run to retry)" }
        }

        $curPrefix = ''
        $serial = 0
        foreach ($f in $nefs) {
            if (-not $rightsOk) { $script:ConvFailed++; continue }
            $base = [IO.Path]::GetFileName($f)
            $stem = [IO.Path]::GetFileNameWithoutExtension($f)
            $dng = ''
            foreach ($c in @((Join-Path $din "$stem.dng"), (Join-Path $din "$stem.DNG"))) {
                if ([IO.File]::Exists($c)) { $dng = $c }
            }
            if (-not $dng) {
                Write-Err "FAIL  DNG conversion: $Day/NEF/.incoming/$base (re-run to retry)"
                $script:ConvFailed++
                continue
            }
            $dt = ''
            if ($dates.ContainsKey($base)) { $dt = $dates[$base] }
            if (-not (Test-Ymd $dt)) { $dt = $Day }
            $prefix = "$dt-$ev"
            # Continue from the highest number already there (e.g. an earlier card).
            if ($prefix -ne $curPrefix) { $curPrefix = $prefix; $serial = Get-NextSerial $dd $prefix }
            $out = Join-Path $dd ($prefix + '-' + $serial.ToString('00000', $inv) + '.dng')
            while (Test-PathExists $out) {
                $serial++
                $out = Join-Path $dd ($prefix + '-' + $serial.ToString('00000', $inv) + '.dng')
            }
            $moved = $false
            try { [IO.File]::Move($dng, $out); $moved = $true } catch { Write-Verbose "move failed: $_" }
            if ($moved -and [IO.File]::Exists($out) -and -not [IO.File]::Exists($dng)) {
                $serial++
                $script:Converted++
                Move-ToFinal $f $nd $names
            } else {
                Write-Err "FAIL  could not file $dng"
                $script:ConvFailed++
            }
        }
        Remove-Tree $din
    }
    $nefs = @(Get-IncomingFiles $inc 'nef')
    if ($nefs.Count -eq 0) { Remove-FileQuiet $eventFile; Remove-EmptyDir $inc }
}

function Invoke-EjectCard {   # returns $true when the card is gone
    if ($onWindows -and $Source -match '^[A-Za-z]:\\?$') {
        try {
            $item = (New-Object -ComObject Shell.Application).Namespace(17).ParseName($Source.Substring(0, 2))
            if ($item) {
                $item.InvokeVerb('Eject')
                for ($i = 0; $i -lt 10; $i++) {
                    Start-Sleep -Milliseconds 500
                    $ready = $true
                    try { $ready = (New-Object IO.DriveInfo $Source.Substring(0, 2)).IsReady } catch { $ready = $false }
                    if (-not $ready -or -not [IO.Directory]::Exists($Source)) { return $true }
                }
            }
        } catch {
            Write-Verbose "eject failed: $_"
        }
        Write-Line "Could not eject $Source - eject it in File Explorer."
    } else {
        Write-Line "Could not eject $Source (it is not a drive root) - eject the card in File Explorer."
    }
    return $false
}

# ---------- main --------------------------------------------------------------
$oldConsoleEncoding = $null
try {
    try {
        $oldConsoleEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = $utf8NoBom     # exiftool output and the (c) sign
    } catch { $oldConsoleEncoding = $null }

    # ---------- validate ----------
    if (-not $EventName) { Stop-Import 'an event name is required (-EventName).' }
    $EventSlug = ([regex]::Replace($EventName.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
    if (-not $EventSlug) { Stop-Import "event name '$EventName' has no usable letters or digits." }
    if ($Date -and -not (Test-Ymd $Date)) { Stop-Import "-Date must be YYYYMMDD, got '$Date'." }

    if (-not $Destination) { Stop-Import 'a destination root is required (-Destination or PHOTO_IMPORT_DEST).' }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { Stop-Import "destination '$Destination' not found." }
    $DestRoot = Get-CleanPath (Resolve-Path -LiteralPath $Destination).ProviderPath    # the DNG converter needs absolute paths
    if (-not $DryRun) {
        $probe = Join-Path $DestRoot ('.photo-import-write-test-' + [guid]::NewGuid().ToString('N'))
        try { [IO.File]::WriteAllText($probe, ''); [IO.File]::Delete($probe) } catch { Stop-Import "destination '$DestRoot' is not writable." }
    }

    if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
        Stop-Import "exiftool not found. Install it with: winget install OliverBetz.ExifTool"
    }
    if (-not (Test-Path -LiteralPath $RenameScript -PathType Leaf)) {
        Stop-Import "phototools_rename_nef.ps1 not found next to this script ($PSScriptRoot)."
    }
    if (-not $SkipDng -and -not $DryRun -and -not (Test-Path -LiteralPath $DngConverter -PathType Leaf)) {
        Stop-Import ("Adobe DNG Converter not found at:`n  $DngConverter`n" +
            "Install it from Adobe, set DNG_CONVERTER to its path, or use -SkipDng to skip DNG conversion.")
    }

    # The card: the drive with a DCIM folder at its root (other than the destination).
    if (-not $Source) {
        $found = 0
        foreach ($drv in [IO.DriveInfo]::GetDrives()) {
            try {
                if (-not $drv.IsReady) { continue }
                $root = $drv.RootDirectory.FullName
                if (-not [IO.Directory]::Exists((Join-Path $root 'DCIM'))) { continue }
                if ((Get-CleanPath $root).Equals($DestRoot, $nameCompare)) { continue }
                $Source = $root; $found++
            } catch { continue }
        }
        if ($found -eq 0) { Stop-Import 'no SD card found (no drive has a DCIM folder). Use -Source to name one.' }
        if ($found -gt 1) { Stop-Import 'more than one drive has a DCIM folder - name the card with -Source.' }
    }
    if ($Source -match '^[A-Za-z]:$') { $Source += '\' }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Stop-Import "source '$Source' not found." }
    $Source = Get-CleanPath (Resolve-Path -LiteralPath $Source).ProviderPath

    $Manifest = Join-Path $DestRoot '.photo-import-manifest.tsv'
    if (-not [IO.File]::Exists($Manifest) -and -not $DryRun) { [IO.File]::WriteAllText($Manifest, '', $utf8NoBom) }
    $ManifestSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ([IO.File]::Exists($Manifest)) {
        foreach ($m in [IO.File]::ReadAllLines($Manifest, $utf8NoBom)) { $null = $ManifestSet.Add($m.TrimEnd("`r")) }
    }

    Write-Line "Event:   $EventSlug"
    Write-Line "Card:    $Source"
    Write-Line "Dest:    $DestRoot"
    if (-not $SkipDng) {
        if ($CopyrightOwner) {
            Write-Line "Rights:  $copySign <capture year> $CopyrightOwner"
        } else {
            Write-Line 'Rights:  none (set -CopyrightOwner or PHOTO_COPYRIGHT_OWNER to add a copyright)'
        }
    }
    Write-Line ''

    # ---------- 1. plan: what is new on the card, and which date is it? ----------
    $scan = $Source
    if ([IO.Directory]::Exists((Join-Path $Source 'DCIM'))) { $scan = Join-Path $Source 'DCIM' }
    $files = @(Get-ScanFiles $scan)

    # Capture time for every file: one exiftool pass per chunk: path, YYYYMMDDHHMMSS, subsec.
    $exif = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' $nameComparer
    if ($files.Count -gt 0) {
        Write-Line "Reading capture dates from $($files.Count) file(s)..."
        $chunkSize = 200
        $timeArgs = @('-q', '-q', '-m', '-f', '-fast2', '-d', '%Y%m%d%H%M%S',
                      '-p', ('$Directory/$FileName' + "`t" + '$DateTimeOriginal' + "`t" + '$SubSecTimeOriginal'))
        for ($i = 0; $i -lt $files.Count; $i += $chunkSize) {
            Show-Status (Get-IntDiv ($i * 100) $files.Count) "Reading capture dates... $i/$($files.Count)"
            $last = [Math]::Min($i + $chunkSize, $files.Count) - 1
            foreach ($line in @(Invoke-ExifTool ($timeArgs + $files[$i..$last]))) {
                $p = ([string]$line).Split("`t")
                if ($p.Count -lt 2 -or -not $p[0]) { continue }
                $exif[[IO.Path]::GetFullPath($p[0])] = @($p[1], $(if ($p.Count -gt 2) { $p[2] } else { '-' }))
            }
        }
        Clear-Status
    }

    $todo = New-Object 'System.Collections.Generic.List[object]'
    $totalBytes = [long]0
    $nefBytes = [long]0
    $already = 0
    $datesSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $k = 0
    foreach ($f in $files) {
        $k++
        Show-Status (Get-IntDiv ($k * 100) $files.Count) "Checking against the manifest... $k/$($files.Count)"
        $fi = New-Object IO.FileInfo $f
        $name = $fi.Name
        $size = [long]$fi.Length
        $mtime = ([DateTimeOffset]$fi.LastWriteTimeUtc).ToUnixTimeSeconds()
        $dto = '-'; $sub = ''
        if ($exif.ContainsKey($f)) { $dto = $exif[$f][0]; $sub = $exif[$f][1] }
        $sub = $sub -replace '[^0-9]', ''
        # Identity of a file: name + size + EXIF capture time. (Card timestamps
        # can shift an hour with daylight saving, so they're only a fallback.)
        if ($dto -match '^[12][0-9]{13}$') {
            $key = "$name`t$size`t$dto$sub"
        } else {
            $key = "$name`t$size`t$mtime"
        }
        if (-not $Force -and $ManifestSet.Contains($key)) { $already++; continue }

        if ($Date) {
            $d = $Date
        } else {
            $d = if ($dto.Length -ge 8) { $dto.Substring(0, 8) } else { '' }
            if (-not (Test-Ymd $d)) { $d = $fi.LastWriteTime.ToString('yyyyMMdd', $inv) }
        }
        $ext = Get-ExtOf $f
        $todo.Add([pscustomobject]@{ Path = $f; Name = $name; Key = $key; Date = $d; Size = $size; Ext = $ext })
        $totalBytes += $size
        if ($ext -eq 'NEF') { $nefBytes += $size }
    }
    Clear-Status

    # NEFs and JPGs left in .incoming by an interrupted run are finished too.
    $leftover = 0
    $dateDirs = @([IO.Directory]::GetDirectories($DestRoot) | Where-Object { Test-Ymd ([IO.Path]::GetFileName($_)) })
    [Array]::Sort($dateDirs, [StringComparer]::Ordinal)
    foreach ($t in @('NEF', 'JPG')) {
        foreach ($dayDir in $dateDirs) {
            $incDir = [IO.Path]::Combine($dayDir, $t, '.incoming')
            if (-not [IO.Directory]::Exists($incDir)) { continue }
            $n = @(Get-IncomingFiles $incDir $t).Count
            if ($n -eq 0) { continue }
            $d = [IO.Path]::GetFileName($dayDir)
            $leftover += $n
            Write-Line "Resume:  $n $t(s) in $d/$t/.incoming from an earlier run"
            $null = $datesSeen.Add($d)
        }
    }

    Write-Line "New:     $($todo.Count) file(s), $(Get-IntDiv $totalBytes 1048576) MB   (already imported: $already)"
    foreach ($item in $todo) { $null = $datesSeen.Add($item.Date) }
    $dates = @($datesSeen)
    [Array]::Sort($dates, [StringComparer]::Ordinal)
    if ($dates.Count -gt 0) { Write-Line "Dates:   $($dates -join ' ')" }
    Write-Line ''

    if ($todo.Count -eq 0 -and $leftover -eq 0) {
        Write-Line 'Nothing new to import.'
        $script:Finished = $true
        if ($Eject -and -not $DryRun) {
            if (Invoke-EjectCard) { Write-Line "Ejected $Source" }
        }
        exit 0
    }

    # Free-space check: the copies, plus about as much again for the DNGs, plus 1%.
    # Skipped for network (UNC) destinations, where free space cannot be read this way.
    $needKb = 0; $availKb = 0
    if (-not $DestRoot.StartsWith('\\')) {
        try {
            $availKb = Get-IntDiv ((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($DestRoot))).AvailableFreeSpace) 1024
            $needBytes = $totalBytes
            if (-not $SkipDng) { $needBytes += $nefBytes }
            if (-not $SkipDng -and $CompressNef) { $needBytes += $nefBytes }
            $needKb = (Get-IntDiv $needBytes 1024) + (Get-IntDiv $needBytes 102400)
        } catch {
            Write-Verbose "free space unknown: $_"
            $needKb = 0; $availKb = 0
        }
        if ($needKb -gt $availKb) {
            Stop-Import "not enough space on ${DestRoot}: need $(Get-IntDiv $needKb 1024) MB, have $(Get-IntDiv $availKb 1024) MB."
        }
    }

    if ($DryRun) {
        foreach ($item in $todo) {
            Write-Line "WOULD COPY  $($item.Path) -> $($item.Date)/$($item.Ext)/"
        }
        foreach ($day in $dates) {
            if (-not [IO.Directory]::Exists([IO.Path]::Combine($DestRoot, $day, 'prod'))) { Write-Line "WOULD CREATE  $day/prod/" }
        }
        Write-Line ''
        Write-Line 'Dry run complete - nothing was changed. NEFs and JPGs would then be renamed to capture time'
        if (-not $SkipDng) { Write-Line "and the NEFs converted to <date>/DNG/<YYYYMMDD>-$EventSlug-<nnnnn>.dng" }
        if (-not $SkipDng -and $CompressNef) { Write-Line "and each date's NEF/ folder zipped to <date>/NEF.zip" }
        $script:Finished = $true
        exit 0
    }

    # ---------- 2. copy + verify ----------
    $copied = 0; $nefNew = 0
    $doneBytes = [long]0
    $t0 = Get-ElapsedSec
    $i = 0
    foreach ($item in $todo) {
        $i++
        $f = $item.Path; $name = $item.Name; $d = $item.Date; $ext = $item.Ext
        $p = 100
        if ($totalBytes -gt 0) { $p = Get-IntDiv ($doneBytes * 100) $totalBytes }
        Show-Status $p "Copying $i/$($todo.Count) ($p%)  $(Format-SizeH $doneBytes) of $(Format-SizeH $totalBytes)  $(Get-Timing $t0 $doneBytes $totalBytes)  $name"
        $doneBytes += $item.Size
        $dayDir = Join-Path $DestRoot $d
        if ($ext -eq 'NEF' -or $ext -eq 'JPG') {
            $dir = [IO.Path]::Combine($dayDir, $ext, '.incoming')   # new NEFs/JPGs wait here until renamed (+ converted)
        } else {
            $dir = Join-Path $dayDir $ext
        }
        try { $null = [IO.Directory]::CreateDirectory($dir) } catch { Stop-Import "cannot create $dir" }
        # Remember the event for these NEFs, in case the run is interrupted and resumed.
        $eventFile = Join-Path $dir '.event'
        if ($ext -eq 'NEF' -and -not [IO.File]::Exists($eventFile)) {
            [IO.File]::WriteAllText($eventFile, $EventSlug + "`n", $utf8NoBom)
        }

        # Free target name (camera counters roll over: DSC_0001 can repeat).
        # An identical file already there means it's a duplicate - don't copy it.
        $stem = [IO.Path]::GetFileNameWithoutExtension($name)
        $sfx = [IO.Path]::GetExtension($name)
        $target = Join-Path $dir $name
        $n = 0; $ok = 0
        while (Test-PathExists $target) {
            if (Compare-FileBytes $f $target) { $ok = 2; break }
            $n++
            $target = Join-Path $dir "${stem}_$n$sfx"
        }
        if ($ok -eq 2) {
            Add-ManifestKey $item.Key
            $already++
            continue
        }

        try {
            [IO.File]::Copy($f, $target, $false)
            $src = New-Object IO.FileInfo $f
            try {
                [IO.File]::SetLastWriteTimeUtc($target, $src.LastWriteTimeUtc)
                [IO.File]::SetCreationTimeUtc($target, $src.CreationTimeUtc)
            } catch { Write-Verbose "could not set times on ${target}: $_" }
            if ($VerifyBytes) {
                if (Compare-FileBytes $f $target) { $ok = 1 }
            } elseif ((New-Object IO.FileInfo $target).Length -eq $item.Size) {
                $ok = 1
            }
        } catch {
            Write-Verbose "copy failed: $_"
        }
        if ($ok -eq 1) {
            Add-ManifestKey $item.Key
            $copied++
            if ($ext -eq 'NEF') { $nefNew++ }
        } else {
            try { [IO.File]::Delete($target) } catch { Write-Verbose "could not remove ${target}" }
            Clear-Status
            Write-Err "FAIL  copy $f"
            $script:Failed++
        }
    }
    Clear-Status
    Write-Line "Copied $copied file(s) ($nefNew NEF) in $(Format-Hms ((Get-ElapsedSec) - $t0)), $($script:Failed) failed."

    # Every date folder gets an empty prod\ next to NEF\ and DNG\; an existing one is left alone.
    foreach ($day in $dates) {
        $dayDir = Join-Path $DestRoot $day
        if (-not [IO.Directory]::Exists($dayDir)) { continue }
        $prod = Join-Path $dayDir 'prod'
        if ([IO.Directory]::Exists($prod)) { continue }
        try {
            $null = [IO.Directory]::CreateDirectory($prod)
            Write-Line "Created  $day/prod/"
        } catch {
            Write-Err "FAIL  could not create $prod"
            $script:Failed++
        }
    }

    # ---------- 3 + 4 + 5. per date folder: rename, drop duplicates, convert, file, compress ----------
    foreach ($day in $dates) {
        Invoke-JpgStep $day
        Invoke-DateStep $day
        if ($CompressNef -and -not $SkipDng) { Compress-Nef $day }
    }
    Write-Line ''
    if (-not $SkipDng) { Write-Line "Converted $($script:Converted) NEF(s) to DNG, $($script:ConvFailed) failed." }
    if ($script:NefZipped -gt 0) { Write-Line "Compressed $($script:NefZipped) NEF folder(s) to NEF.zip." }
    if ($script:Dupes -gt 0) { Write-Line "Dropped $($script:Dupes) duplicate NEF(s)." }
    if ($script:JpgDupes -gt 0) { Write-Line "Dropped $($script:JpgDupes) duplicate JPG(s)." }

    # ---------- wrap up ----------
    Write-Line ''
    Write-Line "Done in $(Format-Hms (Get-ElapsedSec))."
    foreach ($day in $dates) {
        $dayDir = Join-Path $DestRoot $day
        if (-not [IO.Directory]::Exists($dayDir)) { continue }
        $line = ''
        $subs = @([IO.Directory]::GetDirectories($dayDir) | Where-Object { -not [IO.Path]::GetFileName($_).StartsWith('.') })
        [Array]::Sort($subs, [StringComparer]::OrdinalIgnoreCase)
        foreach ($sub in $subs) {
            $c = 0
            foreach ($sf in [IO.Directory]::GetFiles($sub)) {
                if (-not [IO.Path]::GetFileName($sf).StartsWith('.')) { $c++ }
            }
            $line += "  $([IO.Path]::GetFileName($sub))/ $c"
        }
        Write-Line "  ${day}:$line"
    }

    $script:Finished = $true
    if ($script:Failed -gt 0 -or $script:ConvFailed -gt 0) {
        Write-Line ''
        Write-Line 'Some files had problems (see FAIL lines above). The card was NOT ejected.'
        exit 2
    }

    if ($Eject) {
        if (Invoke-EjectCard) { Write-Line "Ejected $Source" }
    }
    exit 0
} finally {
    if (-not $script:Finished) {
        # Ctrl-C or an unexpected error: stop the converter (it ignores Ctrl-C itself).
        try { if ($script:ConvProc -and -not $script:ConvProc.HasExited) { try { $script:ConvProc.Kill($true) } catch { $script:ConvProc.Kill() } } } catch { Write-Verbose 'converter already gone' }
        Write-Line ''
        Write-Err 'Interrupted - re-run the same command to finish.'
    }
    if ($oldConsoleEncoding) { try { [Console]::OutputEncoding = $oldConsoleEncoding } catch { Write-Verbose 'could not restore console encoding' } }
}
