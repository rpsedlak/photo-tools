<#
.SYNOPSIS
Move every blob in a named Azure Blob container to the Archive access tier, to save storage costs.

.DESCRIPTION
phototools_archive_container.ps1 - the Windows PowerShell version of phototools_archive_container.sh.
Runs on Windows PowerShell 5.1 and PowerShell 7+.

  SAFETY   Nothing is changed by default. The tool shows what it found, then
           asks once before acting (it needs a console to ask on). Use -Yes to
           skip the question, or -DryRun to only report.
  ARCHIVE  Blobs are moved to the Archive access tier (cheapest storage;
           reading a blob again takes hours and has a 180 day minimum
           charge). Blobs already archived are skipped, as are blob types
           that cannot be archived (only block blobs can).

Sign-in is the same as phototools_upload_azure.ps1: your 'az login', or a
service principal (-Identity sp). A service principal client secret comes from
PHOTO_AZ_CLIENT_SECRET, AZURE_CLIENT_SECRET, or a Microsoft.PowerShell.SecretManagement
vault secret named photo-tools-azure-<client ID> (change it with
PHOTO_AZ_SECRET_NAME); it cannot be passed on the command line. The identity
needs the 'Storage Blob Data Contributor' role.

Exit status: 0 done (or nothing to do, or not confirmed), 2 some blobs could
not be archived, 1 error.

Requires: Azure CLI (winget install Microsoft.AzureCLI) on PATH.

.PARAMETER Account
Name of the Azure storage account (default: $env:PHOTO_AZ_ACCOUNT).

.PARAMETER Container
The container to archive (required).

.PARAMETER DryRun
Dry run: report folders and counts, change nothing.

.PARAMETER Yes
Do not ask; archive right away.

.PARAMETER List
List every blob (not just the counts per folder).

.PARAMETER Identity
Azure identity (default: $env:PHOTO_AZ_AUTH, else user): user = your 'az login',
sp = a service principal (needs -ClientId, -TenantId and a credential).

.PARAMETER ClientId
Service principal application (client) ID (default: $env:PHOTO_AZ_CLIENT_ID,
else $env:AZURE_CLIENT_ID).

.PARAMETER TenantId
Entra tenant ID (default: $env:PHOTO_AZ_TENANT_ID, else $env:AZURE_TENANT_ID).

.PARAMETER CertificatePath
Service principal certificate: an unencrypted PEM file (default:
$env:PHOTO_AZ_CERT_PATH, else $env:AZURE_CLIENT_CERTIFICATE_PATH).

.PARAMETER VerboseLog
Show the Azure CLI commands being run (default: off). (This is not the common
-Verbose parameter.)

.EXAMPLE
.\phototools_archive_container.ps1 -Account storageaccount -Container charlevoix -DryRun

.EXAMPLE
.\phototools_archive_container.ps1 -Account storageaccount -Container charlevoix -Yes
#>
[CmdletBinding()]
param(
    [string]$Account,
    [string]$Container,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$List,
    [ValidateSet('user', 'sp')]
    [string]$Identity,
    [string]$ClientId,
    [string]$TenantId,
    [string]$CertificatePath,
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Continue'     # native stderr must never become a terminating error
$inv = [Globalization.CultureInfo]::InvariantCulture
$Workers = 8
$script:AzDir = ''
$script:Bound = $PSBoundParameters

# ---------- helpers -----------------------------------------------------------
function Write-Err { param([string]$Text) [Console]::Error.WriteLine($Text) }
function Die {
    param([string]$Text)
    Write-Err "Error: $Text"
    exit 1
}
function Write-VLog { param([string]$Text) if ($VerboseLog) { Write-Err "verbose: $Text" } }
function Get-Env {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v) { return '' }
    return $v
}
function Get-Setting {      # option value when given, else the first non-empty environment variable
    param([string]$Option, [string]$OptionValue, [string[]]$EnvNames, [string]$Default = '')
    if ($script:Bound.ContainsKey($Option)) { return $OptionValue }
    foreach ($n in $EnvNames) {
        $v = Get-Env $n
        if ($v -ne '') { return $v }
    }
    return $Default
}
function Format-Gb { param([double]$Bytes) return ($Bytes / 1000000000).ToString('F3', $inv) }
function Sort-Ordinal {
    param([string[]]$Items)
    $copy = [string[]]@($Items)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return , $copy
}
function Get-Folder {   # blob name -> its folder ('' for the container root)
    param([string]$Name)
    $i = $Name.LastIndexOf('/')
    if ($i -lt 0) { return '' }
    return $Name.Substring(0, $i)
}
function Get-First {    # the first of several property values that is not $null
    foreach ($v in $args) { if ($null -ne $v) { return $v } }
    return $null
}
function Get-BlobInfo {
    param($Blob)
    $p = $Blob.properties
    $size = Get-First $p.contentLength $p.content_length $Blob.contentLength 0
    $tier = Get-First $p.blobTier $p.blob_tier $p.accessTier $p.access_tier ''
    $kind = Get-First $p.blobType $p.blob_type $Blob.blobType 'BlockBlob'
    $name = [string](Get-First $Blob.name '')
    return [pscustomobject]@{ Name = $name; Size = [long]$size; Tier = [string]$tier; Kind = [string]$kind }
}

# ---------- settings ----------------------------------------------------------
$sAccount = Get-Setting 'Account' $Account @('PHOTO_AZ_ACCOUNT')
$sAuth = Get-Setting 'Identity' $Identity @('PHOTO_AZ_AUTH') 'user'
$sClientId = Get-Setting 'ClientId' $ClientId @('PHOTO_AZ_CLIENT_ID', 'AZURE_CLIENT_ID')
$sTenantId = Get-Setting 'TenantId' $TenantId @('PHOTO_AZ_TENANT_ID', 'AZURE_TENANT_ID')
$sCertPath = Get-Setting 'CertificatePath' $CertificatePath @('PHOTO_AZ_CERT_PATH', 'AZURE_CLIENT_CERTIFICATE_PATH')

if ($sAccount -eq '') { Die 'storage account is required; pass -Account or set PHOTO_AZ_ACCOUNT.' }
if ($sAccount -cmatch '[^a-z0-9]') { Die "invalid storage account name '$sAccount'." }
if ($sAccount.Length -lt 3 -or $sAccount.Length -gt 24) { Die 'storage account names must be 3-24 lowercase letters or digits.' }
if (-not $Container) { Die 'container is required; pass -Container.' }
if ($Container -cmatch '[^a-z0-9-]' -or $Container.StartsWith('-') -or $Container.EndsWith('-') -or $Container.Contains('--')) {
    Die "'$Container' is not a valid container name."
}
if ($Container.Length -lt 3 -or $Container.Length -gt 63) { Die "'$Container' is not a valid container name (3-63 characters)." }
if ($sAuth -ieq 'user') { $sAuth = 'user' }
elseif ($sAuth -ieq 'sp') { $sAuth = 'sp' }
else { Die "-Identity must be 'user' or 'sp', got '$sAuth'." }
if ($sAuth -eq 'sp') {
    $missing = ''
    if ($sClientId -eq '') { $missing += "`n  app (client) ID: -ClientId, PHOTO_AZ_CLIENT_ID or AZURE_CLIENT_ID" }
    if ($sTenantId -eq '') { $missing += "`n  tenant ID:       -TenantId, PHOTO_AZ_TENANT_ID or AZURE_TENANT_ID" }
    if ($missing -ne '') { Die "service principal sign-in (-Identity sp) needs:$missing" }
}

$azCmd = Get-Command az -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $azCmd) { Die 'Azure CLI (az) is required. Install it with: winget install Microsoft.AzureCLI' }
$AzExe = $azCmd.Source

# ---------- Azure CLI ---------------------------------------------------------
function Invoke-Az {    # run az; returns Code, Out (text) and Err (text)
    param([string[]]$AzArgs)
    Write-VLog ('az ' + ($AzArgs -join ' '))
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $global:LASTEXITCODE = 0
        $out = & $AzExe @AzArgs 2> $errFile
        $code = $LASTEXITCODE
        $err = ''
        try { $err = [IO.File]::ReadAllText($errFile).Trim() } catch { $err = '' }
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Code = $code; Out = (@($out | ForEach-Object { [string]$_ }) -join "`n"); Err = $err }
}
function Get-AzJson {   # run az with JSON output; returns the parsed items as a list
    param([string[]]$AzArgs)
    $r = Invoke-Az ($AzArgs + @('--output', 'json'))
    if ($r.Code -ne 0) {
        if ($r.Err) { Write-Err $r.Err }
        throw 'Azure CLI command failed.'
    }
    $items = New-Object System.Collections.Generic.List[object]
    if ($r.Out.Trim() -eq '') { return , $items }
    try { $parsed = ConvertFrom-Json $r.Out -ErrorAction Stop } catch { throw 'Azure CLI returned invalid JSON.' }
    foreach ($i in $parsed) { if ($null -ne $i) { $items.Add($i) } }
    return , $items
}
function Invoke-AzQuiet {   # like Invoke-Az, without logging the arguments (they may hold a secret)
    param([string[]]$AzArgs)
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $global:LASTEXITCODE = 0
        $null = & $AzExe @AzArgs 2> $errFile
        $code = $LASTEXITCODE
        $err = ''
        try { $err = [IO.File]::ReadAllText($errFile).Trim() } catch { $err = '' }
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Code = $code; Out = ''; Err = $err }
}

function Connect-ServicePrincipal {     # signs in with a private Azure CLI profile, so your own 'az login' is left alone
    $secret = ''
    $cert = $sCertPath
    if ($cert -ne '') {
        if (-not [IO.Path]::IsPathRooted($cert)) { $cert = [IO.Path]::Combine((Get-Location).ProviderPath, $cert) }
        if (-not (Test-Path -LiteralPath $cert -PathType Leaf)) { Die "certificate '$cert' not found or not readable." }
    }
    elseif ((Get-Env 'PHOTO_AZ_CLIENT_SECRET') -ne '') { $secret = Get-Env 'PHOTO_AZ_CLIENT_SECRET' }
    elseif ((Get-Env 'AZURE_CLIENT_SECRET') -ne '') { $secret = Get-Env 'AZURE_CLIENT_SECRET' }
    else {
        $secretName = Get-Env 'PHOTO_AZ_SECRET_NAME'
        if ($secretName -eq '') { $secretName = 'photo-tools-azure-' + $sClientId }
        if (Get-Command Get-Secret -ErrorAction SilentlyContinue) {
            try { $secret = [string](Get-Secret -Name $secretName -AsPlainText -ErrorAction Stop) } catch { $secret = '' }
        }
        if ($secret -eq '') {
            Die "no credential for service principal $sClientId. Provide a certificate with -CertificatePath, PHOTO_AZ_CERT_PATH or AZURE_CLIENT_CERTIFICATE_PATH; a client secret with PHOTO_AZ_CLIENT_SECRET or AZURE_CLIENT_SECRET; or a SecretManagement secret named '$secretName'."
        }
    }
    $script:AzDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'photo-azure-az.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try { $null = New-Item -ItemType Directory -Path $script:AzDir -Force -ErrorAction Stop }
    catch { Die 'cannot create a temporary Azure CLI profile.' }
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { & chmod 700 $script:AzDir 2>$null }
    [Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', $script:AzDir)
    Write-VLog "az login --service-principal -u $sClientId --tenant $sTenantId (credential not shown)"
    if ($cert -ne '') {
        $r = Invoke-AzQuiet @('login', '--service-principal', '-u', $sClientId, '--tenant', $sTenantId, '--certificate', $cert, '--allow-no-subscriptions', '-o', 'none')
    }
    else {
        $r = Invoke-AzQuiet @('login', '--service-principal', '-u', $sClientId, '--tenant', $sTenantId, '-p', $secret, '--allow-no-subscriptions', '-o', 'none')
    }
    if ($r.Code -ne 0) {
        Write-Err 'Error: service principal sign-in failed:'
        @($r.Err -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 5) | ForEach-Object { Write-Err "  $_" }
        exit 1
    }
}
# Run az once for each argument list, $Workers at a time; results come back in input order.
function Invoke-AzParallel {
    param([object[]]$ArgLists, [scriptblock]$OnProgress)
    $body = {
        param($Exe, $CmdArgs)
        $errFile = [IO.Path]::GetTempFileName()
        try {
            $global:LASTEXITCODE = 0
            $null = & $Exe @CmdArgs 2> $errFile
            $code = $LASTEXITCODE
            $err = ''
            try { $err = [IO.File]::ReadAllText($errFile).Trim() } catch { $err = '' }
        }
        finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
        [pscustomobject]@{ Ok = ($code -eq 0); Error = $err }
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, $Workers)
    $pool.Open()
    try {
        $jobs = New-Object System.Collections.Generic.List[object]
        foreach ($a in $ArgLists) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($body).AddArgument($AzExe).AddArgument([string[]]$a)
            $jobs.Add([pscustomobject]@{ Shell = $ps; Handle = $ps.BeginInvoke() })
        }
        $results = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            $j = $jobs[$i]
            $r = $j.Shell.EndInvoke($j.Handle)
            $j.Shell.Dispose()
            if ($r -and $r.Count -gt 0) { $results.Add($r[0]) } else { $results.Add([pscustomobject]@{ Ok = $false; Error = 'no result' }) }
            & $OnProgress ($i + 1)
        }
        return , $results
    }
    finally { $pool.Close(); $pool.Dispose() }
}

# ---------- main --------------------------------------------------------------
$savedEnv = @{}
foreach ($k in @('AZURE_CONFIG_DIR', 'PYTHONIOENCODING')) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
$savedOutEnc = $null
try { $savedOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $savedOutEnc = $null }
[Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8')
$exitCode = 0
try {
    if ($sAuth -eq 'sp') { Connect-ServicePrincipal }

    Write-Output ('Archive container: {0}/{1}{2}' -f $sAccount, $Container, $(if ($DryRun) { ' (dry run)' } else { '' }))
    try {
        $blobs = Get-AzJson @('storage', 'blob', 'list', '--account-name', $sAccount, '--container-name', $Container,
                              '--auth-mode', 'login', '--num-results', '*')
    }
    catch { Die $_.Exception.Message }

    $plan = New-Object System.Collections.Generic.List[object]
    $archived = New-Object System.Collections.Generic.List[string]
    $unsupported = New-Object System.Collections.Generic.List[string]
    foreach ($b in $blobs) {
        $info = Get-BlobInfo $b
        if ($info.Kind -ine 'BlockBlob') { $unsupported.Add($info.Name) }
        elseif ($info.Tier -ieq 'Archive') { $archived.Add($info.Name) }
        else { $plan.Add($info) }
    }

    Write-Output ''
    if ($plan.Count -gt 0) {
        $folders = @{}
        foreach ($p in $plan) {
            $f = Get-Folder $p.Name
            if (-not $folders.ContainsKey($f)) { $folders[$f] = [long[]]@(0, 0) }
            $folders[$f][0]++
            $folders[$f][1] += $p.Size
        }
        Write-Output ('  {0,-52} {1,8} {2,10}' -f 'Folder', 'Blobs', 'Size (GB)')
        foreach ($f in (Sort-Ordinal @($folders.Keys))) {
            $label = if ($f -eq '') { '(container root)' } else { $f }
            Write-Output ('  {0,-52} {1,8} {2,10}' -f $label, $folders[$f][0], (Format-Gb $folders[$f][1]))
        }
        if ($List) {
            $bySize = @{}
            foreach ($p in $plan) { $bySize[$p.Name] = $p.Size }
            foreach ($n in (Sort-Ordinal @($bySize.Keys))) { Write-Output ('    {0} ({1} GB)' -f $n, (Format-Gb $bySize[$n])) }
        }
    }
    else { Write-Output '  nothing to archive' }
    if ($List) {
        foreach ($n in (Sort-Ordinal @($archived))) { Write-Output "    $n (already in Archive tier, skipped)" }
        foreach ($n in (Sort-Ordinal @($unsupported))) { Write-Output "    $n (skipped, not a block blob)" }
    }

    $totalBytes = [long]0
    foreach ($p in $plan) { $totalBytes += $p.Size }
    Write-Output ''
    Write-Output ('Total: {0} blob(s), {1} GB to archive' -f $plan.Count, (Format-Gb $totalBytes))
    Write-Output "Already in the Archive tier (skipped): $($archived.Count)"
    Write-Output "Blobs that cannot be archived (skipped): $($unsupported.Count)"
    if ($plan.Count -eq 0) { exit 0 }
    if ($DryRun) {
        Write-Output 'Dry run: nothing was changed.'
        exit 0
    }

    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Die 'nothing was changed. There is no console to ask on; run again with -Yes to archive.'
        }
        [Console]::Out.Write(("Move {0} blob(s) ({1} GB) in '{2}' to the Archive tier? They take hours to read again. [y/N] " -f $plan.Count, (Format-Gb $totalBytes), $Container))
        $answer = [Console]::In.ReadLine()
        if ($null -eq $answer -or $answer.Trim() -notmatch '^(y|yes)$') {
            Write-Output 'Cancelled; nothing was changed.'
            exit 0
        }
    }

    $argLists = @(foreach ($p in $plan) {
        , @('storage', 'blob', 'set-tier', '--account-name', $sAccount, '--container-name', $Container,
            ('--name=' + $p.Name), '--tier', 'Archive', '--auth-mode', 'login', '--only-show-errors')
    })
    if ($VerboseLog) { foreach ($a in $argLists) { Write-VLog ('az ' + ($a -join ' ')) } }
    $script:Step = -1
    $total = $plan.Count
    $results = Invoke-AzParallel $argLists {
        param($Done)
        if ([math]::Floor($Done * 10 / $total) -ne $script:Step) {
            $script:Step = [int][math]::Floor($Done * 10 / $total)
            Write-Host "  $Done/$total processed"
        }
    }
    $failures = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $plan.Count; $i++) {
        if (-not $results[$i].Ok) {
            $lines = @($results[$i].Error -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
            $reason = if ($lines.Count -gt 0) { $lines[-1] } else { 'unknown error' }
            $failures.Add("  $Container/$($plan[$i].Name): $reason")
        }
    }
    Write-Output "Archived $($plan.Count - $failures.Count) blob(s)."
    if ($failures.Count -gt 0) {
        Write-Err "Failed: $($failures.Count) blob(s):"
        foreach ($f in $failures) { Write-Err $f }
        $exitCode = 2
    }
}
finally {
    foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    if ($null -ne $savedOutEnc) { try { [Console]::OutputEncoding = $savedOutEnc } catch { Write-Verbose 'could not restore console encoding' } }
    if ($script:AzDir -ne '') { Remove-Item -LiteralPath $script:AzDir -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
