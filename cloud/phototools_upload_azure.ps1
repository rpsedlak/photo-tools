<#
.SYNOPSIS
Uploads photo folders to Azure Blob Storage, one container per category, with azcopy.

.DESCRIPTION
phototools_upload_azure.ps1 - the Windows PowerShell version of phototools_upload_azure.sh.
Runs on Windows PowerShell 5.1 and PowerShell 7+.

  SIGN IN  As you (your existing `az login`), or as a service principal
           (-Identity sp) with a certificate or a client secret.
  ACCESS   By default the script creates its own short-lived user delegation
           SAS for each container (signed with Entra ID, never with account
           keys) and hands it to azcopy. With -Transfer oauth, azcopy signs in
           itself instead and renews its own tokens (best for very long runs).
  UPLOAD   Every file under each folder is uploaded to its container,
           keeping the folder structure:
               DIR\20261017\DNG\a.dng -> <container>/<prefix>/20261017/DNG/a.dng
           Hidden files and folders (names starting with '.') are skipped.
           Blobs that are already in the container are skipped, so a re-run
           only sends what is new. Each blob gets an MD5 hash.
  RETRY    Files that could not be uploaded are listed at the end and linked
           from a retry folder (default DIR\.upload-retry\<container>\),
           keeping their folder structure; retry-manifest.tsv there records
           where each one came from and why it failed. (Windows symbolic links
           need administrator rights or Developer Mode, so the retry entry is a
           hard link to the original, or a copy when a hard link is not
           possible, e.g. on another drive.) Re-run the same command with
           -RetryMode to upload only those files: each successful retry removes
           its retry entry; the original stays where it was.

Exit status: 0 all files uploaded (or already there), 2 some files failed
and were put in the retry folder, 1 nothing was uploaded (error).

Requires: Azure CLI (winget install Microsoft.AzureCLI) and azcopy
(winget install Microsoft.Azure.AZCopy.10), both on PATH.

.PARAMETER Account
Name of the Azure storage account that holds the containers: the first part of
https://ACCOUNT.blob.core.windows.net, 3-24 lowercase letters/digits, e.g.
rpsphotography001; not a URL, resource group or container (default:
$env:PHOTO_AZ_ACCOUNT). List yours with:
az storage account list --query "[].name" -o tsv

.PARAMETER Upload
One or more CONTAINER=DIR items: upload folder DIR into container CONTAINER
(one item for each category), e.g. -Upload 'raw=D:\Photos\Raw','edits=D:\Photos\Edits'

.PARAMETER MapFile
Read CONTAINER=DIR (or CONTAINER<TAB>DIR) lines from a file; blank lines and
# comments are ignored. A leading ~ in DIR means your user profile folder.

.PARAMETER Prefix
Optional extra folder in front of everything uploaded, e.g. 2026 puts
DIR\20261017\a.dng at 2026/20261017/a.dng

.PARAMETER RetryFolder
Retry folder root (default: $env:PHOTO_UPLOAD_RETRY, else DIR\.upload-retry for
each DIR).

.PARAMETER RetryMode
Retry mode: upload only what is in the retry folders.

.PARAMETER Identity
Which Azure identity signs in and uploads (default: $env:PHOTO_AZ_AUTH, else user):
  user  you: reuses your existing 'az login' sign-in. Simplest; use it when you
        run uploads yourself.
  sp    a service principal (an app identity with its own certificate or
        secret): signs in separately, leaving your 'az login' alone. Use it for
        scheduled/unattended runs or to limit access to just the photo storage.
        Needs -ClientId, -TenantId and -CertificatePath or a client secret.
Either one needs the 'Storage Blob Data Contributor' role.

.PARAMETER ClientId
Service principal application (client) ID (default: $env:PHOTO_AZ_CLIENT_ID,
else $env:AZURE_CLIENT_ID).

.PARAMETER TenantId
Entra tenant ID (default: $env:PHOTO_AZ_TENANT_ID, else $env:AZURE_TENANT_ID).

.PARAMETER CertificatePath
Service principal certificate: an unencrypted PEM file holding the private key
and the certificate (default: $env:PHOTO_AZ_CERT_PATH, else
$env:AZURE_CLIENT_CERTIFICATE_PATH).

.PARAMETER Transfer
How azcopy is authorized: sas = a SAS created by this script, oauth = azcopy
signing in itself (default: $env:PHOTO_AZ_TRANSFER, else sas).

.PARAMETER SasHours
SAS lifetime in hours, 1-167 (default 24).

.PARAMETER Tier
Blob tier: Hot, Cool, Cold or Archive (default: the account's).

.PARAMETER Overwrite
Replace a blob when the local file is newer (default: never replace a blob that
is already there).

.PARAMETER DryRun
Dry run: sign in and check access, show what would be uploaded, change nothing.

.PARAMETER VerboseLog
Verbose, for debugging: show each setting and where it came from, every
az/azcopy command (secrets hidden) with its exit code and time, and full error
messages; azcopy logs at INFO level. Also saved to debug.log in the run folder
(except with -DryRun). (This is not the common -Verbose parameter.)

.EXAMPLE
.\phototools_upload_azure.ps1 -Account rpsphotography001 -Upload 'raw=D:\Photos\Raw','edits=D:\Photos\Edits'

Uploads both folders, each into its own container.

.EXAMPLE
.\phototools_upload_azure.ps1 -Account rpsphotography001 -MapFile D:\Photos\containers.txt -Prefix 2026 -DryRun

Shows what would be uploaded, without uploading anything.

.EXAMPLE
.\phototools_upload_azure.ps1 -Account rpsphotography001 -Upload 'raw=D:\Photos\Raw' -RetryMode

Uploads only the files that failed in an earlier run.

.NOTES
Environment (options given on the command line win over these):
  PHOTO_AZ_ACCOUNT        storage account name, e.g. rpsphotography001 (same as -Account)
  PHOTO_AZ_AUTH           user (your az login) or sp (service principal) (same as -Identity)
  PHOTO_AZ_CLIENT_ID      service principal app ID (same as -ClientId; falls back to AZURE_CLIENT_ID)
  PHOTO_AZ_TENANT_ID      tenant ID (same as -TenantId; falls back to AZURE_TENANT_ID)
  PHOTO_AZ_CERT_PATH      certificate PEM (same as -CertificatePath; falls back to AZURE_CLIENT_CERTIFICATE_PATH)
  PHOTO_AZ_CLIENT_SECRET  client secret (falls back to AZURE_CLIENT_SECRET, then
                          a Microsoft.PowerShell.SecretManagement vault secret
                          if that module is installed). There is deliberately no
                          parameter for it: command lines show up in process
                          lists and shell history.
  PHOTO_AZ_SECRET_NAME    name of the SecretManagement secret holding the client
                          secret (default: photo-tools-azure-<client ID>); read
                          with Get-Secret -Name NAME -AsPlainText
  PHOTO_AZ_TRANSFER       sas or oauth (same as -Transfer)
  PHOTO_UPLOAD_RETRY      retry folder root (same as -RetryFolder)
  PHOTO_UPLOAD_LOGS       where run reports and azcopy logs go
                          (default: ~\.photo-tools\upload-runs)
  PHOTO_UPLOAD_VERBOSE    1 = verbose (same as -VerboseLog)

When started with powershell.exe -File or pwsh -File, write several items as one
comma-separated value: -Upload 'raw=D:\Raw,edits=D:\Edits'.
#>
[CmdletBinding()]
param(
    [string]$Account,
    [string[]]$Upload,
    [string[]]$MapFile,
    [string]$Prefix,
    [string]$RetryFolder,
    [switch]$RetryMode,
    [ValidateSet('user', 'sp')]
    [string]$Identity,
    [string]$ClientId,
    [string]$TenantId,
    [string]$CertificatePath,
    [ValidateSet('sas', 'oauth')]
    [string]$Transfer,
    [int]$SasHours = 24,
    [ValidateSet('Hot', 'Cool', 'Cold', 'Archive')]
    [string]$Tier,
    [switch]$Overwrite,
    [switch]$DryRun,
    [switch]$VerboseLog
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'     # native stderr must never become a terminating error
$script:Bound = $PSBoundParameters
$IsWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$Sep = [string][IO.Path]::DirectorySeparatorChar
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Inv = [Globalization.CultureInfo]::InvariantCulture
$PathCmp = if ($IsWin) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$ProgName = 'phototools_upload_azure.ps1'

# ---------- settings ----------------------------------------------------------
function Get-Env {          # an environment variable, '' when unset
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v) { return '' }
    return $v
}
function Get-Setting {      # option value, else the first non-empty environment variable
    param([string]$Option, [string]$OptionValue, [string[]]$EnvNames, [string]$Default = '')
    if ($script:Bound.ContainsKey($Option)) { return $OptionValue }
    foreach ($n in $EnvNames) {
        $v = Get-Env $n
        if ($v -ne '') { return $v }
    }
    return $Default
}
function Get-SettingSource {    # where a setting came from, for the -VerboseLog settings list
    param([string]$Option, [string[]]$EnvNames)
    if ($script:Bound.ContainsKey($Option)) { return "option -$Option" }
    foreach ($n in $EnvNames) {
        if ((Get-Env $n) -ne '') { return "`$env:$n" }
    }
    return 'default'
}

$sAccount = Get-Setting 'Account' $Account @('PHOTO_AZ_ACCOUNT')
$sAuth = Get-Setting 'Identity' $Identity @('PHOTO_AZ_AUTH') 'user'
$sClientId = Get-Setting 'ClientId' $ClientId @('PHOTO_AZ_CLIENT_ID', 'AZURE_CLIENT_ID')
$sTenantId = Get-Setting 'TenantId' $TenantId @('PHOTO_AZ_TENANT_ID', 'AZURE_TENANT_ID')
$sCertPath = Get-Setting 'CertificatePath' $CertificatePath @('PHOTO_AZ_CERT_PATH', 'AZURE_CLIENT_CERTIFICATE_PATH')
$sTransfer = Get-Setting 'Transfer' $Transfer @('PHOTO_AZ_TRANSFER') 'sas'
$sRetryRoot = Get-Setting 'RetryFolder' $RetryFolder @('PHOTO_UPLOAD_RETRY')
$sRunsRoot = Get-Env 'PHOTO_UPLOAD_LOGS'
if ($sRunsRoot -eq '') { $sRunsRoot = [IO.Path]::Combine($HOME, '.photo-tools', 'upload-runs') }
$sSecretName = Get-Env 'PHOTO_AZ_SECRET_NAME'
$sVerbose = ($VerboseLog.IsPresent -or ((Get-Env 'PHOTO_UPLOAD_VERBOSE') -imatch '^(1|y.*|true)$'))
$sPrefix = if ($Prefix) { $Prefix } else { '' }
$sHours = $SasHours
$sTier = if ($Tier) { $Tier } else { '' }
$sOverwrite = $Overwrite.IsPresent
$sRetryMode = $RetryMode.IsPresent
$sDryRun = $DryRun.IsPresent

$BlobSuffix = 'blob.core.windows.net'
$HiddenRe = '(^|/)\.'            # skip hidden files and anything in hidden folders
$GeneralDir = 'general'          # container folder for files directly inside DIR
$ShowFails = 20                  # FAIL lines printed per container; all go in the report
$ErrLines = 3                    # lines of az error output shown (all of them with -VerboseLog)
$script:DebugLog = ''
$script:ProgTty = -not [Console]::IsOutputRedirected
$script:ProgLen = 0
$script:ProgStep = -1
$script:Finished = $false        # set before every normal exit; a finally block that sees it unset was interrupted
$script:Work = ''
$script:AzDir = ''
$script:RunDir = ''
$script:NativeOut = @()
$script:NativeExit = 0
$Clock = [Diagnostics.Stopwatch]::StartNew()

# ---------- output helpers ----------------------------------------------------
function Get-Elapsed { return [long][math]::Floor($Clock.Elapsed.TotalSeconds) }
function Format-Now {
    param([string]$Format)
    return [DateTime]::Now.ToString($Format, $Inv)
}
function Write-Out { param([string]$Text) Write-Host $Text }
function Write-Err { param([string]$Text) [Console]::Error.WriteLine($Text) }
function Write-LogLine { param([string]$Text) Write-Host $Text }
function Write-Warn { param([string]$Text) Write-Err "Warning: $Text" }
function Exit-Script {
    param([int]$Code)
    $script:Finished = $true
    exit $Code
}
function Die {
    param([string]$Text)
    Write-Err "Error: $Text"
    Exit-Script 1
}
function Show-Usage {
    Write-Err @"
Usage:
  $ProgName -Account ACCOUNT -Upload CONTAINER=DIR[,CONTAINER=DIR ...] [options]

  -Account ACCOUNT   storage account name, 3-24 lowercase letters/digits (default: `$env:PHOTO_AZ_ACCOUNT)
  -Upload C=DIR      upload folder DIR into container C (several items allowed)
  -MapFile FILE      read CONTAINER=DIR (or CONTAINER<TAB>DIR) lines from a file
  -Prefix PREFIX     extra folder in front of everything uploaded
  -RetryFolder DIR   retry folder root (default: DIR\.upload-retry)
  -RetryMode         upload only what is in the retry folders
  -Identity user|sp  which Azure identity signs in (default: user)
  -ClientId, -TenantId, -CertificatePath   service principal settings (-Identity sp)
  -Transfer sas|oauth  how azcopy is authorized (default: sas)
  -SasHours HOURS    SAS lifetime, 1-167 (default 24)
  -Tier TIER         Hot, Cool, Cold or Archive
  -Overwrite         replace a blob when the local file is newer
  -DryRun            sign in and check access, change nothing
  -VerboseLog        debugging output

Full help: Get-Help .\$ProgName -Full
"@
    Exit-Script 1
}
function Hide-Secret {   # SAS signatures never reach the screen or a log
    param([string]$Text)
    return [regex]::Replace($Text, '(sig=)[^&"\s]*', '${1}REDACTED')
}
function Clear-ProgressLine {
    if ($script:ProgTty -and $script:ProgLen -gt 0) {
        Write-Host -NoNewline ("`r" + (' ' * $script:ProgLen) + "`r")
    }
    $script:ProgLen = 0
}
function Write-VLog {       # -VerboseLog only: to the screen (stderr) and debug.log, SAS signatures hidden
    param([string]$Message)
    if (-not $sVerbose) { return }
    $line = Hide-Secret ('[{0}] {1}' -f (Format-Now 'HH:mm:ss'), $Message)
    Clear-ProgressLine
    Write-Err "debug $line"
    if ($script:DebugLog -ne '') {
        try { [IO.File]::AppendAllText($script:DebugLog, $line + "`n", $Utf8) } catch { $null = $_ }
    }
}
function Format-CommandLine {   # a command for the log, secrets hidden
    param([string]$Exe, [string[]]$CmdArgs)
    $shown = $Exe
    $hide = $false
    foreach ($a in $CmdArgs) {
        $s = $a
        if ($hide) { $s = '<hidden>'; $hide = $false }
        if ($a -in @('-p', '--password', '--client-secret')) { $hide = $true }
        if ($s -eq '' -or $s -match '\s') { $s = "'$s'" }
        $shown += " $s"
    }
    return $shown
}

# ---------- progress display (same as phototools_import_photos.ps1) ----------------------
function Show-ProgressLine {      # $Percent = percent done, $Text = status text
    param([int]$Percent, [string]$Text)
    if ($script:ProgTty) {
        $width = 0
        try { $width = $Host.UI.RawUI.WindowSize.Width } catch { $width = 0 }
        if ($width -gt 1 -and $Text.Length -ge $width) { $Text = $Text.Substring(0, $width - 1) }
        $pad = ' ' * [math]::Max(0, $script:ProgLen - $Text.Length)
        Write-Host -NoNewline ("`r" + $Text + $pad)
        $script:ProgLen = $Text.Length
    }
    elseif ([math]::Floor($Percent / 10) -ne $script:ProgStep) {
        $script:ProgStep = [int][math]::Floor($Percent / 10)
        Write-Host $Text
    }
}
function Complete-ProgressLine {
    Clear-ProgressLine
    $script:ProgStep = -1
}
function Format-Duration {
    param([long]$Seconds)
    if ($Seconds -ge 3600) {
        return ('{0}h{1:00}m' -f [math]::Floor($Seconds / 3600), [math]::Floor(($Seconds % 3600) / 60))
    }
    return ('{0}m{1:00}s' -f [math]::Floor($Seconds / 60), ($Seconds % 60))
}
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1073741824) {
        return ('{0}.{1} GB' -f [math]::Floor($Bytes / 1073741824), [math]::Floor(($Bytes % 1073741824) * 10 / 1073741824))
    }
    return ('{0} MB' -f [math]::Floor($Bytes / 1048576))
}
function Format-Timing {    # elapsed since $Start, plus an estimate of the time left
    param([long]$Start, [long]$Done, [long]$Total)
    $el = (Get-Elapsed) - $Start
    $text = Format-Duration $el
    if ($Done -gt 0 -and $Done -lt $Total -and $el -ge 2) {
        $text += ', ~{0} left' -f (Format-Duration ([long][math]::Floor($el * ($Total - $Done) / $Done)))
    }
    return $text
}
function Get-UtcIn {        # minutes from now (may be negative) -> 2026-10-21T19:00Z
    param([int]$Minutes)
    return [DateTime]::UtcNow.AddMinutes($Minutes).ToString("yyyy-MM-dd'T'HH:mm'Z'", $Inv)
}

# ---------- path helpers ------------------------------------------------------
function Expand-Tilde {
    param([string]$Path)
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return [IO.Path]::Combine($HOME, $Path.Substring(2))
    }
    return $Path
}
function Get-AbsPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Path))
}
function Get-TrimmedPath {     # keeps a bare root such as C:\ or /
    param([string]$Path)
    $t = $Path.TrimEnd([char[]]@('/', '\'))
    if ($t -eq '' -or $t -match '^[A-Za-z]:$') { return $Path }
    return $t
}
function Join-Relative {    # a '/'-separated relative path under a local folder
    param([string]$Base, [string]$Relative)
    if ($IsWin) { $Relative = $Relative.Replace('/', '\') }
    return [IO.Path]::Combine($Base, $Relative)
}
function Test-Entry {       # exists as anything, including a broken link
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return $true }
    return ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue))
}
function Add-Text {
    param([string]$Path, [string]$Text)
    [IO.File]::AppendAllText($Path, $Text, $Utf8)
}

# ---------- validate options --------------------------------------------------
function Test-ContainerName {   # Azure rules: 3-63 chars, a-z 0-9 and single hyphens inside
    param([string]$Name)
    if ($Name.Length -lt 3 -or $Name.Length -gt 63) { return $false }
    if ($Name -cmatch '[^a-z0-9-]') { return $false }
    if ($Name.StartsWith('-') -or $Name.EndsWith('-') -or $Name.Contains('--')) { return $false }
    return $true
}

if ($sAccount -eq '') {
    Write-Err 'Error: a storage account is required (-Account or PHOTO_AZ_ACCOUNT).'
    Show-Usage
}
if ($sAccount -cmatch '[^a-z0-9]') { Die "storage account '$sAccount' may only contain lowercase letters and digits." }
if ($sAccount.Length -lt 3 -or $sAccount.Length -gt 24) { Die "storage account '$sAccount' must be 3-24 characters." }

if ($sAuth -ieq 'user') { $sAuth = 'user' }
elseif ($sAuth -ieq 'sp') { $sAuth = 'sp' }
else { Die "-Identity must be 'user' or 'sp', got '$sAuth'." }
if ($sTransfer -ieq 'sas') { $sTransfer = 'sas' }
elseif ($sTransfer -ieq 'oauth') { $sTransfer = 'oauth' }
else { Die "-Transfer must be 'sas' or 'oauth', got '$sTransfer'." }
if ($sHours -lt 1 -or $sHours -gt 167) { Die '-SasHours must be 1-167 hours (a user delegation SAS lasts at most 7 days).' }
switch ($sTier.ToLowerInvariant()) {
    ''        { }
    'hot'     { $sTier = 'Hot' }
    'cool'    { $sTier = 'Cool' }
    'cold'    { $sTier = 'Cold' }
    'archive' { $sTier = 'Archive' }
    default   { Die "-Tier must be Hot, Cool, Cold or Archive, got '$sTier'." }
}
$sPrefix = $sPrefix.Replace('\', '/').Trim('/')
if ($sPrefix -cmatch '[^A-Za-z0-9._/-]') { Die "-Prefix may only use letters, digits, '.', '_', '-' and '/', got '$sPrefix'." }
if ($sPrefix -ne '') {
    $wrapped = "/$sPrefix/"
    if ($wrapped.Contains('//') -or $wrapped.Contains('/./') -or $wrapped.Contains('/../')) {
        Die "-Prefix has an empty, '.' or '..' folder: '$sPrefix'."
    }
}

if ($sAuth -eq 'sp') {
    $missing = ''
    if ($sClientId -eq '') { $missing += "`n  app (client) ID: -ClientId, PHOTO_AZ_CLIENT_ID or AZURE_CLIENT_ID" }
    if ($sTenantId -eq '') { $missing += "`n  tenant ID:       -TenantId, PHOTO_AZ_TENANT_ID or AZURE_TENANT_ID" }
    if ($missing -ne '') { Die "service principal sign-in (-Identity sp) needs:$missing" }
}

# ---------- container -> folder list ------------------------------------------
$specLines = New-Object System.Collections.Generic.List[string]
foreach ($item in @($Upload)) {
    if ([string]::IsNullOrEmpty($item)) { continue }
    # powershell -File passes -Upload a=D1,b=D2 as one string: split before each "container=".
    foreach ($part in [regex]::Split($item, ',(?=[a-z0-9][a-z0-9-]*=)')) {
        foreach ($l in ($part -split '[\r\n]+')) { $specLines.Add($l) }
    }
}
foreach ($mf in @($MapFile)) {
    if ([string]::IsNullOrEmpty($mf)) { continue }
    $mfPath = Expand-Tilde $mf
    if (-not (Test-Path -LiteralPath $mfPath -PathType Leaf)) { Die "map file '$mf' not found or not readable." }
    try { $mapText = [IO.File]::ReadAllText((Get-AbsPath $mfPath), $Utf8) }
    catch { Die "map file '$mf' not found or not readable." }
    foreach ($l in ($mapText -split '\n')) { $specLines.Add($l) }
}

$Entries = New-Object System.Collections.Generic.List[object]     # container, absolute folder, retry root
if ($sRetryRoot -ne '') { $sRetryRoot = Get-AbsPath (Get-TrimmedPath (Expand-Tilde $sRetryRoot)) }
foreach ($rawLine in $specLines) {
    $line = $rawLine.Replace("`r", '')
    if ($line.Trim() -eq '' -or $line.TrimStart().StartsWith('#')) { continue }
    $tab = $line.IndexOf("`t")
    $eq = $line.IndexOf('=')
    if ($tab -ge 0) { $cn = $line.Substring(0, $tab); $dn = $line.Substring($tab + 1) }
    elseif ($eq -ge 0) { $cn = $line.Substring(0, $eq); $dn = $line.Substring($eq + 1) }
    else { Die "'$line' is not CONTAINER=DIR." }
    $cn = $cn.Trim()
    $dn = Expand-Tilde $dn.Trim()
    if (-not (Test-ContainerName $cn)) {
        Die "'$cn' is not a valid container name (3-63 characters: lowercase letters, digits and single hyphens, starting and ending with a letter or digit)."
    }
    if ($dn -eq '' -or -not (Test-Path -LiteralPath $dn -PathType Container)) { Die "folder '$dn' for container '$cn' not found." }
    $dn = Get-TrimmedPath ((Resolve-Path -LiteralPath $dn).ProviderPath)
    $dn = Get-AbsPath $dn
    if ($sRetryRoot -ne '') { $rn = $sRetryRoot } else { $rn = [IO.Path]::Combine($dn, '.upload-retry') }
    # A retry folder inside a source folder must be hidden, or it would be uploaded.
    $dnSep = if ($dn.EndsWith($Sep)) { $dn } else { $dn + $Sep }
    if (($rn + $Sep).StartsWith($dnSep, $PathCmp)) {
        $inside = ($rn + $Sep).Substring($dnSep.Length - 1)
        if ($inside -notmatch '[\\/]\.') {
            Die "retry folder '$rn' is inside '$dn' but not hidden; its files would be uploaded again. Use a name starting with '.' or a folder elsewhere."
        }
    }
    $Entries.Add([pscustomobject]@{ Container = $cn; Dir = $dn; Retry = $rn })
}
if ($Entries.Count -eq 0) {
    Write-Err 'Error: name at least one CONTAINER=DIR with -Upload or -MapFile.'
    Show-Usage
}

# ---------- tools -------------------------------------------------------------
function Find-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return ''
}
$AzExe = Find-Tool 'az'
$AzCopyExe = Find-Tool 'azcopy'
if ($AzExe -eq '') { Die 'Azure CLI (az) not found. Install it with: winget install Microsoft.AzureCLI' }
if ($AzCopyExe -eq '') { Die 'azcopy not found. Install it with: winget install Microsoft.Azure.AZCopy.10' }

function Invoke-WithEnv {   # run a script block with extra environment variables, restored afterwards
    param([hashtable]$Vars, [scriptblock]$Body)
    $saved = @{}
    foreach ($k in @($Vars.Keys)) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$Vars[$k])
    }
    try { & $Body }
    finally {
        foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}
function Invoke-Native {    # run az/azcopy, log it with -VerboseLog; output in $script:NativeOut, exit code in $script:NativeExit
    param([string]$Exe, [string[]]$CmdArgs, [string]$ErrFile = '', [hashtable]$EnvVars = @{})
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $t0 = Get-Elapsed
    Write-VLog ('run: ' + (Format-CommandLine $name $CmdArgs))
    $script:NativeOut = @()
    $script:NativeExit = 0
    Invoke-WithEnv $EnvVars {
        $global:LASTEXITCODE = 0
        if ($ErrFile -ne '') { $o = & $Exe @CmdArgs 2> $ErrFile } else { $o = & $Exe @CmdArgs 2> $null }
        $script:NativeExit = $LASTEXITCODE
        $script:NativeOut = @($o | ForEach-Object { [string]$_ })
    } | Out-Null
    Write-VLog ('    exit {0} after {1}s' -f $script:NativeExit, ((Get-Elapsed) - $t0))
}
function Read-ErrFile {     # non-blank lines of an error file
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @([IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() -ne '' -and $_ -ne 'System.Management.Automation.RemoteException' })
}
function Write-ErrFile {    # show the first lines of an error file, indented, SAS signatures hidden
    param([string]$Path, [int]$Max)
    Read-ErrFile $Path | Select-Object -First $Max | ForEach-Object { Write-Err ('  ' + (Hide-Secret $_)) }
}

$azVer = ''
Invoke-Native $AzCopyExe @('--version')
$azVer = ($script:NativeOut -join ' ')
if ($azVer -notmatch ' 10\.') {
    Die "azcopy version 10 is required (found: $(@($script:NativeOut)[0]))."
}
$savedEnv = @{}
foreach ($k in @('AZURE_CONFIG_DIR', 'AZURE_CORE_ONLY_SHOW_ERRORS', 'PYTHONIOENCODING')) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
$savedOutEnc = $null
try { $savedOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8 } catch { $savedOutEnc = $null }
[Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8')
# Warnings from az are hidden normally; with -VerboseLog they are kept, with full errors.
if ($sVerbose) { $ErrLines = 1000 } else { [Environment]::SetEnvironmentVariable('AZURE_CORE_ONLY_SHOW_ERRORS', 'true') }

$script:Work = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'photo-upload.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
try { $null = New-Item -ItemType Directory -Path $script:Work -Force -ErrorAction Stop }
catch { Die 'cannot create a temp folder' }
$Work = $script:Work
$Secret = ''
$Identity_ = ''
$CredDesc = ''
$Report = ''
$GrandOk = 0; $GrandSkip = 0; $GrandFail = 0
$Summary = ''

function Get-LoginHint {    # $Lines = az's error output
    param([string]$Text)
    if ($Text -match 'AADSTS7000222|AADSTS7000215') {
        Write-Err '  The client secret is wrong or has expired. Create a new one with:'
        Write-Err "    az ad sp credential reset --id $sClientId"
    }
    elseif ($Text -match 'AADSTS700027|AADSTS700024|certificate') {
        Write-Err '  The certificate is not registered for this app, has expired, or is not a PEM with the private key.'
        Write-Err "  Register a new one with: az ad sp credential reset --id $sClientId --create-cert"
    }
    elseif ($Text -match 'AADSTS700016') {
        Write-Err "  No app with ID $sClientId in tenant $sTenantId. Check -ClientId and -TenantId."
    }
    elseif ($Text -match 'AADSTS90002') {
        Write-Err "  Tenant '$sTenantId' not found. Check -TenantId."
    }
}

# list_files: "relative path, size, blob name" objects for a folder, hidden files
# skipped. Each first-level subfolder keeps its name in the container; files
# directly inside the folder go into $GeneralDir. Paths use '/' and are sorted
# ordinally. In retry mode links are followed (every file counts as a normal file).
function Get-FileList {
    param([string]$Folder, [string]$BlobPrefix)
    $byRel = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($Folder, ''))
    while ($stack.Count -gt 0) {
        $top = $stack.Pop()
        try { $infos = (New-Object IO.DirectoryInfo $top[0]).GetFileSystemInfos() }
        catch { continue }
        foreach ($fi in $infos) {
            $name = $fi.Name
            if ($name.StartsWith('.')) { continue }
            if (-not $sRetryMode -and ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $lt = ''
                try { $lt = [string]$fi.LinkType } catch { $lt = '' }
                if ($lt -eq 'SymbolicLink' -or $lt -eq 'Junction') { continue }
            }
            $rel = if ($top[1] -ne '') { $top[1] + '/' + $name } else { $name }
            if ($fi.Attributes -band [IO.FileAttributes]::Directory) {
                $stack.Push(@($fi.FullName, $rel))
            }
            else {
                $blob = $BlobPrefix + $(if ($rel.Contains('/')) { $rel } else { "$GeneralDir/$rel" })
                $byRel[$rel] = [pscustomobject]@{ Rel = $rel; Size = [long]$fi.Length; Blob = $blob }
            }
        }
    }
    $keys = [string[]]@($byRel.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) { $list.Add($byRel[$k]) }
    return , $list
}

# A loose file and a file of the same name in DIR\general\ would both become
# general/NAME; stop before uploading rather than let one replace the other.
function Test-GeneralClash {
    param([string]$Folder, $List)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($f in $List) { $null = $seen.Add($f.Rel) }
    $clash = New-Object System.Collections.Generic.List[string]
    foreach ($f in $List) {
        if (-not $f.Rel.Contains('/') -and $seen.Contains("$GeneralDir/" + $f.Rel)) { $clash.Add($f.Rel) }
    }
    if ($clash.Count -gt 0) {
        $sorted = [string[]]@($clash)
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $shownClash = ($sorted | Select-Object -First 10 | ForEach-Object { "  $_" }) -join "`n"
        Die "these files in $Folder would land on the same blob as files in its '$GeneralDir' subfolder (files directly in the folder go to $GeneralDir/):`n$shownClash`nRename or move one of each pair, then run again."
    }
}

function Clear-EmptyFolder {  # like find -type d -empty -delete: bottom-up, links not followed
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    foreach ($sub in [IO.Directory]::GetDirectories($Path)) {
        $attr = [IO.File]::GetAttributes($sub)
        if (-not ($attr -band [IO.FileAttributes]::ReparsePoint)) { Clear-EmptyFolder $sub }
    }
    if (@([IO.Directory]::GetFileSystemEntries($Path)).Count -eq 0) {
        try { [IO.Directory]::Delete($Path) } catch { $null = $_ }
    }
}

function Add-RetryEntry {   # a hard link to the original, else a copy; $true when it worked
    param([string]$Where, [string]$Original)
    try {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Where))
        try {
            $null = New-Item -ItemType HardLink -Path $Where -Value $Original -ErrorAction Stop
        }
        catch {
            Copy-Item -LiteralPath $Original -Destination $Where -ErrorAction Stop
        }
        return (Test-Path -LiteralPath $Where -PathType Leaf)
    }
    catch { return $false }
}

function Get-FailReason {   # $Status = azcopy status, $Code = HTTP error code
    param([string]$Status, [string]$Code)
    if ($Status -eq 'Failed') {
        if ($Code -eq '403') { return 'HTTP 403: access denied (SAS expired, role missing, or blocked by the account firewall)' }
        if ($Code -eq '404') { return 'HTTP 404: container not found' }
        if ($Code -eq '0' -or $Code -eq '') { return 'transfer failed (network error or unreadable file; see the azcopy log)' }
        return "HTTP $Code"
    }
    return 'not uploaded: azcopy stopped before reaching this file'
}

function Receive-AzCopyLine {   # one line of azcopy's JSON output; $Ctx carries the state of the current job
    param([string]$Raw, [hashtable]$Ctx)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return }
    $j = $null
    if ($Raw.TrimStart().StartsWith('{')) {
        try { $j = $Raw | ConvertFrom-Json -ErrorAction Stop } catch { $j = $null }
    }
    if ($null -eq $j) {
        Write-VLog "azcopy: $Raw"
        if (-not $Raw.StartsWith('INFO:')) { $Ctx.Errors.Add((Hide-Secret $Raw)) }
        return
    }
    $type = [string]$j.MessageType
    if ($type -eq 'Init') {
        $jobId = [string](($j.MessageContent | ConvertFrom-Json).JobID)
        $Ctx.Jobs.Add($jobId)
        Write-VLog "azcopy job ${jobId}; log: $($Ctx.LogDir)$Sep$jobId.log"
    }
    elseif ($type -eq 'Progress') {
        $m = $j.MessageContent | ConvertFrom-Json
        $doneN = $Ctx.Base + [long]$m.TransfersCompleted + [long]$m.TransfersFailed + [long]$m.TransfersSkipped
        $pct = [int][math]::Floor($doneN * 100 / $Ctx.N)
        Show-ProgressLine $pct ('    {0}/{1} file(s), {2} sent, {3}' -f $doneN, $Ctx.N, (Format-Size ([long]$m.TotalBytesTransferred)), (Format-Timing $Ctx.T0 $doneN $Ctx.N))
    }
    elseif ($type -eq 'Error') {
        $text = (Hide-Secret ([string]$j.MessageContent)) -replace '[\t\r\n]', ' '
        $Ctx.Errors.Add($text)
        Write-VLog "azcopy error: $text"
    }
}

function Get-AzCopyAuthEnv {    # extra environment for the azcopy process only
    $e = @{}
    if ($sTransfer -ne 'oauth') { return $e }
    if ($sAuth -eq 'sp') {
        $e['AZCOPY_AUTO_LOGIN_TYPE'] = 'SPN'
        $e['AZCOPY_SPA_APPLICATION_ID'] = $sClientId
        $e['AZCOPY_TENANT_ID'] = $sTenantId
        if ($sCertPath -ne '') { $e['AZCOPY_SPA_CERT_PATH'] = $sCertPath }
        else { $e['AZCOPY_SPA_CLIENT_SECRET'] = $Secret }
    }
    else { $e['AZCOPY_AUTO_LOGIN_TYPE'] = 'AZCLI' }
    Write-VLog ('azcopy sign-in: ' + ((@($e.Keys) | Sort-Object) -join ' ') + ' (values not shown)')
    return $e
}

# $script:Finished stays $false until a normal exit; a finally block that sees that was interrupted (Ctrl-C).
try {
    try {
        if ($sVerbose) {
            $script:DebugLog = [IO.Path]::Combine($Work, 'debug.log')
            Write-VLog "$ProgName $(Format-Now 'yyyy-MM-dd HH:mm:ss'), pid $PID"
            $azV = ''
            Invoke-Native $AzExe @('version', '-o', 'json')
            try { $azV = [string](($script:NativeOut -join "`n" | ConvertFrom-Json).'azure-cli') } catch { $azV = '' }
            Write-VLog "tools: $(@($azVer -split ' ')[0..2] -join ' '); az $azV; PowerShell $($PSVersionTable.PSVersion); $([Environment]::OSVersion.VersionString)"
            Write-VLog "paths: az=$AzExe azcopy=$AzCopyExe"
            Write-VLog "setting account   = $sAccount  [$(Get-SettingSource 'Account' @('PHOTO_AZ_ACCOUNT'))]"
            Write-VLog "setting auth      = $sAuth  [$(Get-SettingSource 'Identity' @('PHOTO_AZ_AUTH'))]"
            if ($sAuth -eq 'sp') {
                Write-VLog "setting client id = $(if ($sClientId) { $sClientId } else { '<none>' })  [$(Get-SettingSource 'ClientId' @('PHOTO_AZ_CLIENT_ID', 'AZURE_CLIENT_ID'))]"
                Write-VLog "setting tenant id = $(if ($sTenantId) { $sTenantId } else { '<none>' })  [$(Get-SettingSource 'TenantId' @('PHOTO_AZ_TENANT_ID', 'AZURE_TENANT_ID'))]"
                Write-VLog "setting cert      = $(if ($sCertPath) { $sCertPath } else { '<none>' })  [$(Get-SettingSource 'CertificatePath' @('PHOTO_AZ_CERT_PATH', 'AZURE_CLIENT_CERTIFICATE_PATH'))]"
                if ((Get-Env 'PHOTO_AZ_CLIENT_SECRET') -ne '') { $secretDesc = 'set in $env:PHOTO_AZ_CLIENT_SECRET' }
                elseif ((Get-Env 'AZURE_CLIENT_SECRET') -ne '') { $secretDesc = 'set in $env:AZURE_CLIENT_SECRET' }
                else { $secretDesc = "not in the environment (SecretManagement secret '$(if ($sSecretName) { $sSecretName } else { 'photo-tools-azure-' + $sClientId })' is tried)" }
                Write-VLog "setting secret    = $secretDesc"
            }
            Write-VLog "setting transfer  = $sTransfer  [$(Get-SettingSource 'Transfer' @('PHOTO_AZ_TRANSFER'))]"
            Write-VLog "setting prefix    = $(if ($sPrefix) { $sPrefix } else { '<none>' }); SAS hours = $sHours; tier = $(if ($sTier) { $sTier } else { '<account default>' }); overwrite = $(if ($sOverwrite) { 'ifSourceNewer' } else { 'false' }); retry mode = $([int]$sRetryMode); dry run = $([int]$sDryRun)"
            Write-VLog "setting retry     = $(if ($sRetryRoot) { $sRetryRoot } else { 'DIR\.upload-retry' })  [$(Get-SettingSource 'RetryFolder' @('PHOTO_UPLOAD_RETRY'))]"
            Write-VLog "setting logs      = $sRunsRoot  [$(Get-SettingSource 'x' @('PHOTO_UPLOAD_LOGS'))]"
            foreach ($e in $Entries) { Write-VLog "folder  $($e.Container) <- $($e.Dir)  (retry root $($e.Retry))" }
            $cfgDir = Get-Env 'AZURE_CONFIG_DIR'
            Write-VLog "AZURE_CONFIG_DIR=$(if ($cfgDir) { $cfgDir } else { '<default ~\.azure>' })"
        }

        # ---------- 1. sign in ----------------------------------------------------
        if ($sAuth -eq 'user') {
            Invoke-Native $AzExe @('account', 'show', '--query', 'user.name', '-o', 'tsv')
            if ($script:NativeExit -ne 0) { Die 'you are not signed in to the Azure CLI. Run: az login   (or use -Identity sp for a service principal)' }
            $who = (($script:NativeOut -join '').Trim())
            $Identity_ = "user:$who"
            $CredDesc = 'your Azure CLI sign-in'
            if ($sVerbose) {
                Invoke-Native $AzExe @('account', 'show', '--query', '[name, id, tenantId]', '-o', 'tsv')
                Write-VLog ('az account: ' + (($script:NativeOut -join ' ') -replace '[\t\r\n]', ' '))
            }
        }
        else {
            if ($sCertPath -ne '') {
                $sCertPath = Get-AbsPath (Expand-Tilde $sCertPath)
                if (-not (Test-Path -LiteralPath $sCertPath -PathType Leaf)) { Die "certificate '$sCertPath' not found or not readable." }
                if (-not $IsWin) {
                    $perm = ''
                    $statCmd = Find-Tool 'stat'
                    if ($statCmd -ne '') {
                        $perm = (@(& $statCmd -c %a $sCertPath 2>$null) -join '').Trim()
                        if ($perm -eq '') { $perm = (@(& $statCmd -f %Lp $sCertPath 2>$null) -join '').Trim() }
                    }
                    if ($perm -ne '' -and -not $perm.EndsWith('00')) {
                        Write-Warn "$sCertPath can be read by other users (mode $perm). Run: chmod 600 `"$sCertPath`""
                    }
                }
                $CredDesc = "certificate $sCertPath"
            }
            elseif ((Get-Env 'PHOTO_AZ_CLIENT_SECRET') -ne '') {
                $Secret = Get-Env 'PHOTO_AZ_CLIENT_SECRET'; $CredDesc = 'client secret from PHOTO_AZ_CLIENT_SECRET'
            }
            elseif ((Get-Env 'AZURE_CLIENT_SECRET') -ne '') {
                $Secret = Get-Env 'AZURE_CLIENT_SECRET'; $CredDesc = 'client secret from AZURE_CLIENT_SECRET'
            }
            else {
                $secretName = if ($sSecretName -ne '') { $sSecretName } else { 'photo-tools-azure-' + $sClientId }
                if (Get-Command Get-Secret -ErrorAction SilentlyContinue) {
                    Write-VLog "run: Get-Secret -Name $secretName -AsPlainText"
                    try { $Secret = [string](Get-Secret -Name $secretName -AsPlainText -ErrorAction Stop) } catch { $Secret = '' }
                }
                if ($Secret -eq '') {
                    Die @"
no credential for service principal $sClientId. Provide one of:
  a certificate:   -CertificatePath PEM, PHOTO_AZ_CERT_PATH or AZURE_CLIENT_CERTIFICATE_PATH
  a client secret: PHOTO_AZ_CLIENT_SECRET or AZURE_CLIENT_SECRET
  a vault secret:  Set-Secret -Name $secretName -Secret <the client secret>
                   (needs the Microsoft.PowerShell.SecretManagement module and a registered vault)
"@
                }
                $CredDesc = "client secret from SecretManagement secret '$secretName'"
            }

            # A private Azure CLI profile, so your own `az login` is left untouched.
            $script:AzDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'photo-upload-az.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            try { $null = New-Item -ItemType Directory -Path $script:AzDir -Force -ErrorAction Stop }
            catch { Die 'cannot create a temp folder' }
            if (-not $IsWin) { & chmod 700 $script:AzDir 2>$null }
            [Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', $script:AzDir)
            Write-LogLine "Signing in as service principal $sClientId ($CredDesc)..."
            $loginErr = [IO.Path]::Combine($Work, 'login.err')
            if ($sCertPath -ne '') {
                Invoke-Native $AzExe @('login', '--service-principal', '-u', $sClientId, '--tenant', $sTenantId, '--certificate', $sCertPath, '--allow-no-subscriptions', '-o', 'none') $loginErr
            }
            else {
                Invoke-Native $AzExe @('login', '--service-principal', '-u', $sClientId, '--tenant', $sTenantId, '-p', $Secret, '--allow-no-subscriptions', '-o', 'none') $loginErr
            }
            if ($script:NativeExit -ne 0) {
                Write-Err 'Error: service principal sign-in failed:'
                Write-ErrFile $loginErr ($ErrLines + 2)
                Get-LoginHint ((Read-ErrFile $loginErr) -join "`n")
                Exit-Script 1
            }
            $Identity_ = "sp:$sClientId"
        }

        # ---------- 2. check every container before anything is uploaded ----------
        Write-LogLine "Account: $sAccount  ($BlobSuffix)"
        Write-LogLine "Sign-in: $Identity_  ($CredDesc)"
        if ($sTransfer -eq 'sas') { Write-LogLine "Access:  user delegation SAS per container, valid $sHours h" }
        else { Write-LogLine 'Access:  azcopy signs in itself (OAuth)' }
        if ($sRetryMode) { Write-LogLine 'Mode:    retry (only files in the retry folders)' }
        Write-LogLine ''

        $existsErr = [IO.Path]::Combine($Work, 'exists.err')
        $checked = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($e in $Entries) {
            $cont = $e.Container
            if (-not $checked.Add($cont)) { continue }
            Invoke-Native $AzExe @('storage', 'container', 'exists', '--account-name', $sAccount, '-n', $cont, '--auth-mode', 'login', '--query', 'exists', '-o', 'tsv') $existsErr
            if ($script:NativeExit -ne 0) {
                Write-Err "Error: cannot reach container '$cont' in '$sAccount' as ${Identity_}:"
                Write-ErrFile $existsErr $ErrLines
                if (((Read-ErrFile $existsErr) -join "`n") -match 'AuthorizationPermissionMismatch|AuthorizationFailure|not authorized|403') {
                    Write-Err "  $Identity_ needs the 'Storage Blob Data Contributor' role on storage account $sAccount"
                    Write-Err "  (or on container $cont). New role assignments can take up to 10 minutes to apply."
                    Write-Err '  If the account has a firewall, your public IP must also be allowed.'
                }
                Exit-Script 1
            }
            $existsOut = ($script:NativeOut -join '').Trim()
            Write-VLog "container $cont exists: $existsOut"
            if ($existsOut -ne 'true') { Die "container '$cont' does not exist in storage account '$sAccount'. Create it first (this script never creates containers)." }
            # "exists" only needs a management role such as Owner; reading blobs needs
            # a data role, which uploads need too, so check that before uploading.
            Invoke-Native $AzExe @('storage', 'blob', 'list', '--account-name', $sAccount, '-c', $cont, '--auth-mode', 'login', '--num-results', '1', '--query', '[].name', '-o', 'tsv') $existsErr
            if ($script:NativeExit -ne 0) {
                Write-Err "Error: $Identity_ can see container '$cont' in '$sAccount' but cannot read or upload blobs:"
                Write-ErrFile $existsErr $ErrLines
                Write-Err "  Owner and Contributor don't include blob data access. $Identity_ needs the"
                Write-Err "  'Storage Blob Data Contributor' role on storage account $sAccount (or on container $cont)."
                Write-Err '  New role assignments can take up to 10 minutes to apply.'
                Exit-Script 1
            }
        }

        # ---------- 3. what to upload ---------------------------------------------
        # One "job" per container + source folder. In retry mode the source is the
        # retry folder for that container, uploaded with no prefix, because the
        # retry folder already holds the full blob path.
        $Jobs = New-Object System.Collections.Generic.List[object]
        foreach ($e in $Entries) {
            $cont = $e.Container
            if ($sRetryMode) {
                $src = [IO.Path]::Combine($e.Retry, $cont)
                $dup = $false
                foreach ($jb in $Jobs) { if ([string]::Equals($jb.Src, $src, $PathCmp)) { $dup = $true } }
                if ($dup) { continue }
                if (-not (Test-Path -LiteralPath $src -PathType Container)) { Write-LogLine "${cont}: nothing to retry ($src not found)"; continue }
                $Jobs.Add([pscustomobject]@{ Container = $cont; Src = $src; Prefix = ''; Retry = $e.Retry })
            }
            else {
                $Jobs.Add([pscustomobject]@{ Container = $cont; Src = $e.Dir; Prefix = $sPrefix; Retry = $e.Retry })
            }
        }
        if ($Jobs.Count -eq 0) { Write-LogLine 'Nothing to do.'; Exit-Script 0 }

        if ($sDryRun) {
            foreach ($jb in $Jobs) {
                $cont = $jb.Container; $src = $jb.Src
                $bp = if ($jb.Prefix -ne '') { $jb.Prefix + '/' } else { '' }
                $list = Get-FileList $src $bp
                Test-GeneralClash $src $list
                $n = $list.Count
                $loose = @($list | Where-Object { -not $_.Rel.Contains('/') }).Count
                $bytes = [long]0
                foreach ($f in $list) { $bytes += $f.Size }
                Write-LogLine ('{0}: WOULD upload {1} file(s), {2}' -f $cont, $n, (Format-Size $bytes))
                Write-LogLine "    from  $src"
                Write-LogLine "    to    https://$sAccount.$BlobSuffix/$cont/$bp"
                if ($loose -ne 0) { Write-LogLine "          ($loose file(s) directly in the folder go to $bp$GeneralDir/)" }
                if (-not $sRetryMode) { Write-LogLine ('    retry ' + [IO.Path]::Combine($jb.Retry, $cont) + $Sep) }
                foreach ($f in ($list | Select-Object -First 5)) { Write-LogLine ('      ' + $f.Rel + '  ->  ' + $f.Blob) }
                if ($n -gt 5) { Write-LogLine ('      ... and {0} more' -f ($n - 5)) }
            }
            Write-LogLine ''
            Write-LogLine 'Dry run complete -- signed in and checked access; nothing was uploaded or moved.'
            Exit-Script 0
        }

        $RunDir = [IO.Path]::Combine($sRunsRoot, ('{0}-{1}' -f (Format-Now 'yyyyMMdd-HHmmss'), $PID))
        try { $null = New-Item -ItemType Directory -Path $RunDir -Force -ErrorAction Stop }
        catch { Die "cannot create $RunDir" }
        if (-not $IsWin) { & chmod 700 $RunDir 2>$null }
        $script:RunDir = $RunDir
        $LogDir = [IO.Path]::Combine($RunDir, 'logs')
        $PlanDir = [IO.Path]::Combine($RunDir, 'plans')
        $AzCopyBaseEnv = @{ AZCOPY_LOG_LOCATION = $LogDir; AZCOPY_JOB_PLAN_LOCATION = $PlanDir }
        $Report = [IO.Path]::Combine($RunDir, 'report.txt')
        if ($sVerbose) {
            try { Copy-Item -LiteralPath $script:DebugLog -Destination ([IO.Path]::Combine($RunDir, 'debug.log')) -Force -ErrorAction Stop } catch { $null = $_ }
            $script:DebugLog = [IO.Path]::Combine($RunDir, 'debug.log')
            Write-VLog "run folder $RunDir (debug.log, report.txt, azcopy logs in logs/)"
        }
        $head = "$ProgName  $(Format-Now 'yyyy-MM-dd HH:mm:ss')`naccount   $sAccount`nidentity  $Identity_ ($CredDesc)`naccess    $sTransfer`n"
        if ($sRetryMode) { $head += "mode      retry`n" }
        [IO.File]::WriteAllText($Report, $head + "`n", $Utf8)

        # ---------- 4. upload -----------------------------------------------------
        $RunStart = Get-Elapsed
        $Now = Format-Now "yyyy-MM-dd'T'HH:mm:ss"
        $ManifestHeader = "# container`tblob`toriginal path`ttime`tidentity`terror"
        $jIndex = 0
        foreach ($jb in $Jobs) {
            $jIndex++
            $cont = $jb.Container; $src = $jb.Src; $bp = if ($jb.Prefix -ne '') { $jb.Prefix + '/' } else { '' }; $r = $jb.Retry
            $manifest = [IO.Path]::Combine($r, 'retry-manifest.tsv')
            $list = Get-FileList $src $bp
            Test-GeneralClash $src $list
            $n = $list.Count
            $loose = @($list | Where-Object { -not $_.Rel.Contains('/') }).Count
            if ($jIndex -ne 1) { Write-LogLine '' }
            if ($n -eq 0) { Write-LogLine "${cont}: nothing to upload in $src"; continue }
            $bytes = [long]0
            foreach ($f in $list) { $bytes += $f.Size }
            Write-LogLine ('{0}: uploading {1} file(s), {2} from {3}' -f $cont, $n, (Format-Size $bytes), $src)

            $dest = "https://$sAccount.$BlobSuffix/$cont"
            if ($bp -ne '') { $dest += '/' + $jb.Prefix }
            $sas = ''
            $url = $dest
            if ($sTransfer -eq 'sas') {
                Invoke-Native $AzExe @('storage', 'container', 'generate-sas', '--account-name', $sAccount, '-n', $cont,
                    '--as-user', '--auth-mode', 'login', '--permissions', 'rcwl', '--https-only',
                    '--start', (Get-UtcIn -5), '--expiry', (Get-UtcIn ($sHours * 60)), '-o', 'tsv') ([IO.Path]::Combine($Work, 'sas.err'))
                $sas = if ($script:NativeExit -eq 0) { ($script:NativeOut -join '').Trim() } else { '' }
                if ($sas -notmatch 'sig=') {
                    Write-Err "Error: could not create a SAS for container '$cont':"
                    Write-ErrFile ([IO.Path]::Combine($Work, 'sas.err')) $ErrLines
                    Write-Err "  $Identity_ needs 'Storage Blob Data Contributor' (or 'Storage Blob Delegator') on $sAccount."
                    Exit-Script 1
                }
                $url = "${dest}?$sas"
                Write-VLog "SAS for ${cont}: $sas"
            }

            # Two azcopy passes: subfolders keep their names (top-level files left
            # out), then the files directly in the folder go into $GeneralDir.
            # azcopy matches --exclude-regex against the relative path with '/' separators on every platform.
            $ctx = @{ Jobs = (New-Object System.Collections.Generic.List[string]); Errors = (New-Object System.Collections.Generic.List[string]); Base = [long]0; N = [long]$n; T0 = (Get-Elapsed); LogDir = $LogDir }
            foreach ($pass in @('sub', 'loose')) {
                if ($pass -eq 'sub') {
                    $passN = $n - $loose
                    $copyArgs = @('copy', ([IO.Path]::Combine($src, '*')), $url, '--recursive', '--exclude-regex', "$HiddenRe|^[^/]+`$")
                }
                else {
                    $passN = $loose
                    $passUrl = "$dest/$GeneralDir"
                    if ($sas -ne '') { $passUrl += "?$sas" }
                    $copyArgs = @('copy', ([IO.Path]::Combine($src, '*')), $passUrl, '--exclude-regex', $HiddenRe)
                }
                if ($passN -le 0) { continue }
                $copyArgs += @('--put-md5', '--block-size-mb=40', '--cap-mbps=0', ('--log-level=' + $(if ($sVerbose) { 'INFO' } else { 'WARNING' })), '--output-type=json')
                if ($sOverwrite) { $copyArgs += '--overwrite=ifSourceNewer' } else { $copyArgs += '--overwrite=false' }
                if ($sTier -ne '') { $copyArgs += "--block-blob-tier=$sTier" }

                Write-VLog "pass ${pass}: $passN file(s); run: $(Format-CommandLine 'azcopy' $copyArgs)"
                $copyEnv = Get-AzCopyAuthEnv
                foreach ($k in @($AzCopyBaseEnv.Keys)) { $copyEnv[$k] = $AzCopyBaseEnv[$k] }
                Invoke-WithEnv $copyEnv {
                    & $AzCopyExe @copyArgs 2>&1 | ForEach-Object { Receive-AzCopyLine ([string]$_) $ctx }
                } | Out-Null
                $ctx.Base += $passN
            }
            Complete-ProgressLine
            $sas = ''; $url = ''; $passUrl = ''; $copyArgs = @()

            # Per-file outcome from azcopy's job record: source path, status, HTTP code.
            $statusMap = New-Object System.Collections.Hashtable ($(if ($IsWin) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
            $srcNorm = $src
            if ($IsWin) { $srcNorm = $srcNorm.Replace('\', '/') }
            $srcPrefix = $srcNorm.TrimEnd('/') + '/'
            $statusCounts = @{}
            foreach ($jid in $ctx.Jobs) {
                Invoke-Native $AzCopyExe @('jobs', 'show', $jid, '--with-status=All', '--output-type=json') '' $AzCopyBaseEnv
                foreach ($jl in $script:NativeOut) {
                    if (-not $jl.TrimStart().StartsWith('{')) { continue }
                    try { $jo = $jl | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    if ([string]$jo.MessageType -ne 'ListJobTransfers') { continue }
                    $content = $jo.MessageContent | ConvertFrom-Json
                    foreach ($d in @($content.Details)) {
                        if ($null -eq $d -or $d.IsFolderProperties -eq $true) { continue }
                        $s = [string]$d.Src
                        if ($IsWin) {
                            $s = $s.Replace('\', '/')
                            if ($s.StartsWith('//?/')) { $s = $s.Substring(4) }
                        }
                        if ($s.StartsWith($srcPrefix, $PathCmp)) { $s = $s.Substring($srcPrefix.Length) }
                        $statusMap[$s] = @([string]$d.TransferStatus, [string]$d.ErrorCode)
                        $statusCounts[[string]$d.TransferStatus] = 1 + $(if ($statusCounts.ContainsKey([string]$d.TransferStatus)) { $statusCounts[[string]$d.TransferStatus] } else { 0 })
                    }
                }
            }
            $jobText = $ctx.Jobs -join ' '
            Write-VLog ('job(s) {0} transfer status: {1}' -f $(if ($jobText) { $jobText } else { '<none>' }), ((@($statusCounts.Keys) | Sort-Object | ForEach-Object { "$_=$($statusCounts[$_])" }) -join ', '))

            # A skipped file only counts if the blob already there is the same size;
            # otherwise a different photo with that name is in the way.
            $blobs = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
            $anySkipped = $false
            foreach ($v in $statusMap.Values) { if ($v[0] -like 'Skipped*') { $anySkipped = $true; break } }
            if ($anySkipped) {
                $blobArgs = @('storage', 'blob', 'list', '--account-name', $sAccount, '-c', $cont, '--auth-mode', 'login')
                if ($bp -ne '') { $blobArgs += @('--prefix', $bp) }
                $blobArgs += @('--num-results', '*', '--query', '[].[name, properties.contentLength]', '-o', 'tsv')
                Invoke-Native $AzExe $blobArgs ''
                if ($script:NativeExit -ne 0) { Write-Warn "could not list $cont to check skipped files; they are treated as failed." }
                else {
                    foreach ($bl in $script:NativeOut) {
                        $t = $bl.IndexOf("`t")
                        if ($t -gt 0) { $blobs[$bl.Substring(0, $t)] = $bl.Substring($t + 1).Trim() }
                    }
                }
            }

            $outcome = New-Object System.Collections.Generic.List[object]
            foreach ($f in $list) {
                if ($statusMap.ContainsKey($f.Rel)) { $sv = $statusMap[$f.Rel] } else { $sv = @('Missing', '0') }
                if ($sv[0] -eq 'Success') { $o = 'ok' }
                elseif ($sv[0] -like 'Skipped*' -and $blobs.ContainsKey($f.Blob) -and $blobs[$f.Blob] -eq [string]$f.Size) { $o = 'skip' }
                else { $o = 'fail' }
                $outcome.Add([pscustomobject]@{ Rel = $f.Rel; Size = $f.Size; O = $o; St = $sv[0]; Code = $sv[1]; Blob = $f.Blob })
            }
            if ($sVerbose) {
                $oc = New-Object System.Text.StringBuilder
                [void]$oc.Append("# file`tsize`toutcome`tazcopy status`tHTTP code`tblob`n")
                foreach ($x in $outcome) { [void]$oc.Append("$($x.Rel)`t$($x.Size)`t$($x.O)`t$($x.St)`t$($x.Code)`t$($x.Blob)`n") }
                $ocPath = [IO.Path]::Combine($RunDir, "outcome-$jIndex-$cont.tsv")
                [IO.File]::WriteAllText($ocPath, $oc.ToString(), $Utf8)
                Write-VLog "per-file outcome: $ocPath"
            }

            $firstError = ''
            if ($ctx.Errors.Count -gt 0) { $firstError = $ctx.Errors[0]; if ($firstError.Length -gt 200) { $firstError = $firstError.Substring(0, 200) } }
            $ok = 0; $skip = 0; $fail = 0; $shown = 0; $keptBack = 0
            $manDrop = New-Object System.Collections.Generic.List[string]       # container TAB blob
            $manAdd = New-Object System.Collections.Generic.List[string]
            $origMap = @{}
            if ($sRetryMode -and (Test-Path -LiteralPath $manifest -PathType Leaf)) {
                foreach ($ml in [IO.File]::ReadAllLines($manifest, $Utf8)) {
                    $mp = $ml.Split("`t")
                    if ($mp.Count -ge 3 -and $mp[0] -ceq $cont -and -not $origMap.ContainsKey($mp[1])) { $origMap[$mp[1]] = $mp[2] }
                }
            }

            foreach ($x in $outcome) {
                $rel = $x.Rel; $blob = $x.Blob
                if ($x.O -eq 'fail') {
                    if ($x.St -like 'Skipped*') {
                        if ($sOverwrite) { $reason = "the container already has a newer '$blob' (not replaced)" }
                        else { $reason = "the container already has a different '$blob' (not replaced; -Overwrite replaces it if this file is newer)" }
                    }
                    elseif ($x.St -eq 'Missing') {
                        if ($ctx.Jobs.Count -eq 0 -and $firstError -ne '') { $reason = "not uploaded: $firstError" }
                        else { $reason = Get-FailReason $x.St $x.Code }
                    }
                    else { $reason = Get-FailReason $x.St $x.Code }
                    $reason = $reason -replace '[\t\r\n]', ' '
                    $fail++
                    if ($sRetryMode) {
                        $orig = if ($origMap.ContainsKey($rel)) { $origMap[$rel] } else { '' }
                        $where = Join-Relative $src $rel
                    }
                    else {
                        $orig = Join-Relative $src $rel
                        $where = Join-Relative ([IO.Path]::Combine($r, $cont)) $blob
                        if (Test-Entry $where) {
                            $reason += "; NOT linked: $where already exists"; $where = $orig
                        }
                        elseif (-not ((Test-Path -LiteralPath $orig -PathType Leaf) -and (Add-RetryEntry $where $orig))) {
                            $reason += "; NOT linked: could not create link at $where"; $where = $orig
                        }
                    }
                    $manDrop.Add("$cont`t$blob")
                    $manAdd.Add(("$cont`t$blob`t$(if ($orig) { $orig } else { '?' })`t$Now`t$Identity_`t$reason"))
                    Add-Text $Report ("FAIL  $cont  ${blob}: $reason`n      now at $where`n")
                    if ($shown -lt $ShowFails) { Write-Err "FAIL  $cont/${blob}: $reason"; $shown++ }
                }
                else {
                    if ($x.O -eq 'ok') { $ok++ } else { $skip++ }
                    if (-not $sRetryMode) { continue }
                    # A retried entry is a link or copy of the original, which never left its path.
                    $orig = if ($origMap.ContainsKey($rel)) { $origMap[$rel] } else { '' }
                    $entryPath = Join-Relative $src $rel
                    if ($orig -ne '' -and (Test-Path -LiteralPath $orig -PathType Leaf)) {
                        $removed = $false
                        try { Remove-Item -LiteralPath $entryPath -Force -ErrorAction Stop; $removed = -not (Test-Entry $entryPath) } catch { $removed = $false }
                        if ($removed) { $manDrop.Add("$cont`t$blob"); continue }
                        $note = "uploaded, but retry link was not removed; left at $entryPath"
                        $keptBack++
                        Write-Err "NOTE  $cont/${blob}: $note"
                        Add-Text $Report "NOTE  $cont  ${blob}: $note`n"
                        continue
                    }
                    # Legacy retry files were moved, so restore them to their source path.
                    $manDrop.Add("$cont`t$blob")
                    $moved = $false
                    if ($orig -eq '') { $note = "uploaded, but no original path is recorded; left at $entryPath" }
                    elseif (Test-Entry $orig) { $note = "uploaded, but $orig already exists; left at $entryPath" }
                    else {
                        try {
                            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($orig))
                            Move-Item -LiteralPath $entryPath -Destination $orig -ErrorAction Stop
                            $moved = -not (Test-Entry $entryPath)
                        }
                        catch { $moved = $false }
                        if (-not $moved) { $note = "uploaded, but could not move it back to $orig; left at $entryPath" }
                    }
                    if ($moved) { continue }
                    $keptBack++
                    Write-Err "NOTE  $cont/${blob}: $note"
                    Add-Text $Report "NOTE  $cont  ${blob}: $note`n"
                }
            }
            if ($fail -gt $shown) { Write-Err ('      ... and {0} more (see the report)' -f ($fail - $shown)) }

            # Rewrite the manifest once: drop entries settled in this job, add new failures.
            if ($manDrop.Count -gt 0) {
                try { $null = [IO.Directory]::CreateDirectory($r) } catch { Die "cannot create $r" }
                if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { [IO.File]::WriteAllText($manifest, $ManifestHeader + "`n", $Utf8) }
                $dropSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                foreach ($dr in $manDrop) { $null = $dropSet.Add($dr) }
                $newLines = New-Object System.Collections.Generic.List[string]
                foreach ($ml in [IO.File]::ReadAllLines($manifest, $Utf8)) {
                    if ($ml -eq '') { continue }
                    $mp = $ml.Split("`t")
                    $key = if ($mp.Count -ge 2) { $mp[0] + "`t" + $mp[1] } else { $mp[0] }
                    if (-not $dropSet.Contains($key)) { $newLines.Add($ml) }
                }
                foreach ($ad in $manAdd) { $newLines.Add($ad) }
                $hasData = $false
                foreach ($nl in $newLines) { if (-not $nl.StartsWith('#')) { $hasData = $true; break } }
                if ($hasData) { [IO.File]::WriteAllText($manifest, (($newLines -join "`n") + "`n"), $Utf8) }
                else { Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue }
            }
            # Tidy up emptied retry folders (never the source folders themselves).
            Clear-EmptyFolder ([IO.Path]::Combine($r, $cont))
            if ([IO.Directory]::Exists($r) -and @([IO.Directory]::GetFileSystemEntries($r)).Count -eq 0) {
                try { [IO.Directory]::Delete($r) } catch { $null = $_ }
            }

            if ($fail -gt 1 -and $fail -eq $n) {
                Write-Err '      Every file failed. Check your network, the account firewall, the role assignment'
                Write-Err "      and the SAS lifetime (-SasHours); details are in $LogDir"
                if ($firstError -ne '') { Write-Err "      azcopy said: $firstError" }
            }
            $line = '{0}: {1} uploaded, {2} already there, {3} failed  ({4})' -f $cont, $ok, $skip, $fail, (Format-Duration ((Get-Elapsed) - $ctx.T0))
            if ($keptBack -ne 0) { $line += ", $keptBack left in the retry folder (see NOTE lines)" }
            Write-LogLine "    $line"
            $Summary += "  $line`n"
            $GrandOk += $ok; $GrandSkip += $skip; $GrandFail += $fail
        }

        # ---------- 5. report -----------------------------------------------------
        # The retry folder replaces azcopy's own resume; -VerboseLog keeps the plans for 'azcopy jobs show'.
        if ($sVerbose) { Write-VLog "kept azcopy job plans in $PlanDir" }
        else { Remove-Item -LiteralPath $PlanDir -Recurse -Force -ErrorAction SilentlyContinue }
        Add-Text $Report ("`nsummary`n" + $Summary)

        Write-LogLine ''
        Write-LogLine ('Done in {0}: {1} uploaded, {2} already there, {3} failed.' -f (Format-Duration ((Get-Elapsed) - $RunStart)), $GrandOk, $GrandSkip, $GrandFail)
        Write-Host -NoNewline $Summary
        Write-LogLine "Report:  $Report"
        if ($GrandFail -gt 0) {
            Write-LogLine ''
            if ($sRetryMode) {
                Write-LogLine "$GrandFail file(s) are still in the retry folder. Fix the cause and run the same command again."
            }
            else {
                Write-LogLine "$GrandFail file(s) were put in the retry folder (see FAIL lines above)."
                Write-LogLine 'Fix the cause, then run the same command with -RetryMode to upload only those.'
            }
            Exit-Script 2
        }
        Exit-Script 0
    }
    catch {
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
        Write-Err "Error: unexpected failure: $($_.Exception.Message)"
        Write-Err ("  at " + $_.InvocationInfo.PositionMessage)
        Exit-Script 1
    }
}
finally {
    Write-VLog "exit status $(if ($script:Finished) { 'finished' } else { 'interrupted' })"
    if (-not $script:Finished) {
        Complete-ProgressLine
        Write-Host ''
        Write-Err 'Interrupted. Nothing was put in the retry folder; re-run the same command (files already uploaded are skipped).'
    }
    foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    if ($null -ne $savedOutEnc) { try { [Console]::OutputEncoding = $savedOutEnc } catch { $null = $_ } }
    if ($script:Work -ne '') { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:AzDir -ne '') { Remove-Item -LiteralPath $script:AzDir -Recurse -Force -ErrorAction SilentlyContinue }
}
