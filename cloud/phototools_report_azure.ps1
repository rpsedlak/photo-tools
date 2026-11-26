<#
.SYNOPSIS
Report read-only statistics for an Azure Blob storage account.

.DESCRIPTION
phototools_report_azure.ps1 - the Windows PowerShell version of phototools_report_azure.sh.
Runs on Windows PowerShell 5.1 and PowerShell 7+.

Prints the number of containers, blobs and the total size in GB, with a line
per container. With -Detail FILE it also writes an Excel workbook (.xlsx) with
a summary tab and one tab per container listing every blob. Nothing in the
storage account is changed, and Excel is not needed to create the workbook.

Sign-in is the same as phototools_upload_azure.ps1: your 'az login', or a
service principal (-Identity sp). A service principal client secret comes from
PHOTO_AZ_CLIENT_SECRET, AZURE_CLIENT_SECRET, or a Microsoft.PowerShell.SecretManagement
vault secret named photo-tools-azure-<client ID> (change it with
PHOTO_AZ_SECRET_NAME); it cannot be passed on the command line.

Requires: Azure CLI (winget install Microsoft.AzureCLI) on PATH.

.PARAMETER Account
Name of the Azure storage account (default: $env:PHOTO_AZ_ACCOUNT).

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

.PARAMETER Summary
Print a summary to the console (the default). Cannot be combined with -Detail.

.PARAMETER Detail
Write an Excel workbook with a summary and one tab per container to this file.

.PARAMETER VerboseLog
Show the Azure CLI commands being run (default: off). (This is not the common
-Verbose parameter.)

.EXAMPLE
.\phototools_report_azure.ps1 -Account rpsphotography001

.EXAMPLE
.\phototools_report_azure.ps1 -Account rpsphotography001 -Detail .\azure-report.xlsx
#>
[CmdletBinding()]
param(
    [string]$Account,
    [ValidateSet('user', 'sp')]
    [string]$Identity,
    [string]$ClientId,
    [string]$TenantId,
    [string]$CertificatePath,
    [switch]$Summary,
    [string]$Detail,
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Continue'     # native stderr must never become a terminating error
$inv = [Globalization.CultureInfo]::InvariantCulture
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
    $kindSet = $null -ne (Get-First $p.blobType $p.blob_type $Blob.blobType)
    $name = [string](Get-First $Blob.name '')
    return [pscustomobject]@{ Name = $name; Size = [long]$size; Tier = [string]$tier; Kind = [string]$kind; KindSet = $kindSet }
}

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
# ---------- Excel workbook ----------------------------------------------------
function ConvertTo-Gb { param([double]$Bytes) return [math]::Round($Bytes / 1000000000, 3) }
function Get-ColumnName {
    param([int]$Number)
    $name = ''
    while ($Number -gt 0) {
        $rem = ($Number - 1) % 26
        $name = [string][char](65 + $rem) + $name
        $Number = [int][math]::Floor(($Number - 1) / 26)
    }
    return $name
}
function ConvertTo-XmlText {
    param([string]$Text)
    return [Security.SecurityElement]::Escape(($Text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]', ''))
}
function ConvertTo-WorksheetXml {   # rows: list of arrays; a number is written as a number, anything else as text
    param($Rows)
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n")
    $null = $sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    $rowNumber = 0
    foreach ($values in $Rows) {
        $rowNumber++
        $null = $sb.Append('<row r="' + $rowNumber + '">')
        for ($c = 0; $c -lt $values.Count; $c++) {
            $v = $values[$c]
            if ($null -eq $v) { continue }
            $ref = (Get-ColumnName ($c + 1)) + $rowNumber
            if ($v -is [double] -or $v -is [int] -or $v -is [long]) {
                $null = $sb.Append('<c r="' + $ref + '"><v>' + ([double]$v).ToString('R', $inv) + '</v></c>')
            }
            else {
                $null = $sb.Append('<c r="' + $ref + '" t="inlineStr"><is><t xml:space="preserve">' + (ConvertTo-XmlText ([string]$v)) + '</t></is></c>')
            }
        }
        $null = $sb.Append('</row>')
    }
    $null = $sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}
function Get-SheetNames {
    param([string[]]$Containers)
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $null = $used.Add('summary')
    $null = $used.Add('history')
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Containers) {
        $base = [regex]::Replace($c, '[\[\]:*?/\\]', '_')
        if ($base.Length -gt 31) { $base = $base.Substring(0, 31) }
        $base = $base.Trim("'")
        if ($base -eq '') { $base = 'Container' }
        $name = $base
        $suffix = 2
        while ($used.Contains($name)) {
            $tail = " ($suffix)"
            $name = $base.Substring(0, [math]::Min($base.Length, 31 - $tail.Length)) + $tail
            $suffix++
        }
        $null = $used.Add($name)
        $names.Add($name)
    }
    return , $names
}
function Write-Workbook {
    param([string]$Path, [string[]]$Containers, $BlobsByContainer)
    $blobCount = 0
    $bytes = [long]0
    foreach ($list in $BlobsByContainer) { $blobCount += $list.Count; foreach ($f in $list) { $bytes += $f.Size } }
    $summaryRows = New-Object System.Collections.Generic.List[object]
    $summaryRows.Add(@('Storage account', $sAccount))
    $summaryRows.Add(@('Container count', [long]$Containers.Count))
    $summaryRows.Add(@('Blob count', [long]$blobCount))
    $summaryRows.Add(@('Total size (GB)', (ConvertTo-Gb $bytes)))
    $summaryRows.Add(@())
    $summaryRows.Add(@('Container', 'Blob count', 'Size (GB)'))
    for ($i = 0; $i -lt $Containers.Count; $i++) {
        $sz = [long]0
        foreach ($f in $BlobsByContainer[$i]) { $sz += $f.Size }
        $summaryRows.Add(@($Containers[$i], [long]$BlobsByContainer[$i].Count, (ConvertTo-Gb $sz)))
    }
    $sheetNames = New-Object System.Collections.Generic.List[string]
    $sheetNames.Add('Summary')
    foreach ($n in (Get-SheetNames $Containers)) { $sheetNames.Add($n) }
    $sheetXml = New-Object System.Collections.Generic.List[string]
    $sheetXml.Add((ConvertTo-WorksheetXml $summaryRows))
    for ($i = 0; $i -lt $Containers.Count; $i++) {
        if ($BlobsByContainer[$i].Count + 1 -gt 1048576) { throw 'container has too many blobs for a single Excel worksheet.' }
        $rows = New-Object System.Collections.Generic.List[object]
        $rows.Add(@('Blob name', 'Size (GB)', 'Last modified', 'Blob type', 'Content type', 'Access tier'))
        foreach ($f in $BlobsByContainer[$i]) { $rows.Add(@($f.Name, (ConvertTo-Gb $f.Size), $f.Modified, $f.Type, $f.ContentType, $f.Tier)) }
        $sheetXml.Add((ConvertTo-WorksheetXml $rows))
    }

    $decl = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n"
    $relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $pkgNs = 'http://schemas.openxmlformats.org/package/2006/relationships'
    $ctNs = 'http://schemas.openxmlformats.org/package/2006/content-types'
    $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $rootRels = $decl + '<Relationships xmlns="' + $pkgNs + '"><Relationship Id="rId1" Type="' + $relNs + '/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    $ct = New-Object System.Text.StringBuilder
    $null = $ct.Append($decl + '<Types xmlns="' + $ctNs + '">')
    $null = $ct.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    $null = $ct.Append('<Default Extension="xml" ContentType="application/xml"/>')
    $null = $ct.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    $wb = New-Object System.Text.StringBuilder
    $null = $wb.Append($decl + '<workbook xmlns="' + $mainNs + '" xmlns:r="' + $relNs + '"><sheets>')
    $rels = New-Object System.Text.StringBuilder
    $null = $rels.Append($decl + '<Relationships xmlns="' + $pkgNs + '">')
    for ($i = 1; $i -le $sheetNames.Count; $i++) {
        $null = $wb.Append('<sheet name="' + (ConvertTo-XmlText $sheetNames[$i - 1]) + '" sheetId="' + $i + '" r:id="rId' + $i + '"/>')
        $null = $rels.Append('<Relationship Id="rId' + $i + '" Type="' + $relNs + '/worksheet" Target="worksheets/sheet' + $i + '.xml"/>')
        $null = $ct.Append('<Override PartName="/xl/worksheets/sheet' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')
    }
    $null = $wb.Append('</sheets></workbook>')
    $null = $rels.Append('</Relationships>')
    $null = $ct.Append('</Types>')

    $dir = [IO.Path]::GetDirectoryName($Path)
    $temp = [IO.Path]::Combine($dir, 'azure-report-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        $fs = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                $parts = New-Object System.Collections.Specialized.OrderedDictionary
                $parts['_rels/.rels'] = $rootRels
                $parts['[Content_Types].xml'] = $ct.ToString()
                $parts['xl/workbook.xml'] = $wb.ToString()
                $parts['xl/_rels/workbook.xml.rels'] = $rels.ToString()
                for ($i = 0; $i -lt $sheetXml.Count; $i++) { $parts['xl/worksheets/sheet' + ($i + 1) + '.xml'] = $sheetXml[$i] }
                foreach ($key in @($parts.Keys)) {
                    $entry = $zip.CreateEntry([string]$key, [IO.Compression.CompressionLevel]::Optimal)
                    $stream = $entry.Open()
                    try {
                        $bytesOut = $utf8.GetBytes([string]$parts[$key])
                        $stream.Write($bytesOut, 0, $bytesOut.Length)
                    }
                    finally { $stream.Dispose() }
                }
            }
            finally { $zip.Dispose() }
        }
        finally { $fs.Dispose() }
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# ---------- settings ----------------------------------------------------------
$sAccount = Get-Setting 'Account' $Account @('PHOTO_AZ_ACCOUNT')
$sAuth = Get-Setting 'Identity' $Identity @('PHOTO_AZ_AUTH') 'user'
$sClientId = Get-Setting 'ClientId' $ClientId @('PHOTO_AZ_CLIENT_ID', 'AZURE_CLIENT_ID')
$sTenantId = Get-Setting 'TenantId' $TenantId @('PHOTO_AZ_TENANT_ID', 'AZURE_TENANT_ID')
$sCertPath = Get-Setting 'CertificatePath' $CertificatePath @('PHOTO_AZ_CERT_PATH', 'AZURE_CLIENT_CERTIFICATE_PATH')
$detailMode = $script:Bound.ContainsKey('Detail')

if ($Summary -and $detailMode) { Die '-Summary and -Detail cannot be used together.' }
if ($sAccount -eq '') { Die 'storage account is required; pass -Account or set PHOTO_AZ_ACCOUNT.' }
if ($sAccount -cmatch '[^a-z0-9]') { Die "invalid storage account name '$sAccount'." }
if ($sAccount.Length -lt 3 -or $sAccount.Length -gt 24) { Die 'storage account names must be 3-24 lowercase letters or digits.' }
if ($sAuth -ieq 'user') { $sAuth = 'user' }
elseif ($sAuth -ieq 'sp') { $sAuth = 'sp' }
else { Die "-Identity must be 'user' or 'sp', got '$sAuth'." }
if ($sAuth -eq 'sp') {
    $missing = ''
    if ($sClientId -eq '') { $missing += "`n  app (client) ID: -ClientId, PHOTO_AZ_CLIENT_ID or AZURE_CLIENT_ID" }
    if ($sTenantId -eq '') { $missing += "`n  tenant ID:       -TenantId, PHOTO_AZ_TENANT_ID or AZURE_TENANT_ID" }
    if ($missing -ne '') { Die "service principal sign-in (-Identity sp) needs:$missing" }
}
$outputPath = ''
if ($detailMode) {
    if ([string]::IsNullOrWhiteSpace($Detail)) { Die 'an output file is required with -Detail.' }
    $outputPath = $Detail
    if (-not [IO.Path]::IsPathRooted($outputPath)) { $outputPath = [IO.Path]::Combine((Get-Location).ProviderPath, $outputPath) }
    $outputPath = [IO.Path]::GetFullPath($outputPath)
    Add-Type -AssemblyName System.IO.Compression
}

$azCmd = Get-Command az -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $azCmd) { Die 'Azure CLI (az) is required. Install it with: winget install Microsoft.AzureCLI' }
$AzExe = $azCmd.Source

# ---------- main --------------------------------------------------------------
$savedEnv = @{}
foreach ($k in @('AZURE_CONFIG_DIR', 'PYTHONIOENCODING')) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
$savedOutEnc = $null
try { $savedOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $savedOutEnc = $null }
[Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8')
try {
    if ($sAuth -eq 'sp') { Connect-ServicePrincipal }

    try {
        $data = Get-AzJson @('storage', 'container', 'list', '--account-name', $sAccount, '--auth-mode', 'login', '--num-results', '*')
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($d in $data) { $names.Add([string]$d.name) }
        $containers = [string[]](Sort-Ordinal $names.ToArray())
        $blobsByContainer = New-Object System.Collections.Generic.List[object]
        $counts = New-Object System.Collections.Generic.List[long]
        $sizes = New-Object System.Collections.Generic.List[long]
        foreach ($c in $containers) {
            $blobs = Get-AzJson @('storage', 'blob', 'list', '--account-name', $sAccount, '--container-name', $c, '--auth-mode', 'login', '--num-results', '*')
            $rows = New-Object System.Collections.Generic.List[object]
            $size = [long]0
            foreach ($b in $blobs) {
                $p = $b.properties
                $s = $null
                if ($null -ne $p) { $s = Get-First $p.contentSettings $p.content_settings }
                $info = Get-BlobInfo $b
                $size += $info.Size
                if ($detailMode) {
                    $modified = Get-First $p.lastModified $p.last_modified ''
                    if ($modified -is [datetime]) { $modified = $modified.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", $inv) }
                    $rows.Add([pscustomobject]@{
                        Name = $info.Name; Size = $info.Size; Modified = [string]$modified; Type = $(if ($info.KindSet) { $info.Kind } else { '' })
                        ContentType = [string](Get-First $s.contentType $s.content_type '')
                        Tier = $info.Tier
                    })
                }
            }
            $counts.Add([long]$blobs.Count)
            $sizes.Add($size)
            if ($detailMode) { $blobsByContainer.Add($rows) }
            Write-VLog "${c}: $($blobs.Count) blobs"
        }
        $totalBlobs = [long]0; foreach ($n in $counts) { $totalBlobs += $n }
        $totalBytes = [long]0; foreach ($n in $sizes) { $totalBytes += $n }
        if ($detailMode) {
            Write-Workbook $outputPath $containers $blobsByContainer
            Write-Output "Excel report written to $outputPath"
        }
    }
    catch { Die $_.Exception.Message }

    Write-Output "Azure Storage Blob report: $sAccount"
    Write-Output ('Containers: {0} | Blobs: {1} | Total size: {2} GB' -f $containers.Count, $totalBlobs, (Format-Gb $totalBytes))
    Write-Output ('{0,-32} {1,12} {2,20}' -f 'Container', 'Blobs', 'Size (GB)')
    for ($i = 0; $i -lt $containers.Count; $i++) {
        Write-Output ('{0,-32} {1,12} {2,20}' -f $containers[$i], $counts[$i], (Format-Gb $sizes[$i]))
    }
}
finally {
    foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    if ($null -ne $savedOutEnc) { try { [Console]::OutputEncoding = $savedOutEnc } catch { Write-Verbose 'could not restore console encoding' } }
    if ($script:AzDir -ne '') { Remove-Item -LiteralPath $script:AzDir -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
