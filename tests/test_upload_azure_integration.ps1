$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('photo-upload-test-' + [Guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$names = @('FAKE_ROOT', 'FAKE_EXISTS', 'FAKE_CREATE_FAIL', 'PHOTO_AZ_ACCOUNT', 'PHOTO_AZ_AUTH',
    'PHOTO_AZ_CREATE_CONTAINERS', 'PHOTO_UPLOAD_IGNORE_EXTENSIONS', 'PHOTO_UPLOAD_LOGS', 'PHOTO_UPLOAD_VERBOSE')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Run-Upload([string]$Arguments) {
    $scriptPath = (Join-Path $PSScriptRoot '..\cloud\phototools_upload_azure.ps1').Replace("'", "''")
    $command = "& '$scriptPath' -Account account -Upload 'photos=$($source.Replace("'", "''"))' $Arguments"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $process.WaitForExit()
    return @{ Code = $process.ExitCode; Out = $stdout; Err = $stderr }
}
function Calls([string]$Name) {
    $path = Join-Path $root $Name
    if (Test-Path $path) { return [IO.File]::ReadAllText($path) }
    return ''
}
function Clear-Calls {
    foreach ($name in @('az-calls.txt', 'copy-calls.txt')) {
        $path = Join-Path $root $name
        if (Test-Path $path) { Remove-Item -LiteralPath $path }
    }
}
try {
    $null = New-Item -ItemType Directory -Path $root
    $source = Join-Path $root 'photos'
    $null = New-Item -ItemType Directory -Path (Join-Path $source 'sub') -Force
    Set-Content -LiteralPath (Join-Path $source 'photo.jpg') -Value 'jpg'
    Set-Content -LiteralPath (Join-Path $source 'raw.NEF') -Value 'nef'
    Set-Content -LiteralPath (Join-Path $source 'sub\archive.ZIP') -Value 'zip'
    Set-Content -LiteralPath (Join-Path $source 'sub\image.dng') -Value 'dng'
    [IO.File]::WriteAllText((Join-Path $root 'az.cmd'), @'
@echo off
echo %*>>"%FAKE_ROOT%\az-calls.txt"
if "%1 %2"=="account show" (echo test-user& exit /b 0)
if "%1 %2 %3"=="storage container exists" (echo %FAKE_EXISTS%& exit /b 0)
if "%1 %2 %3"=="storage container create" if "%FAKE_CREATE_FAIL%"=="1" goto createfail
if "%1 %2 %3"=="storage container create" (echo true& exit /b 0)
if "%1 %2 %3"=="storage blob list" exit /b 0
exit /b 1
:createfail
echo creation denied 1>&2
exit /b 1
'@)
    Add-Type -OutputAssembly (Join-Path $root 'azcopy.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
class AzCopy {
    static void Main(string[] args) {
        if (args.Length > 0 && args[0] == "--version") {
            Console.WriteLine("azcopy version 10.1.0");
            return;
        }
        File.AppendAllText(Path.Combine(Environment.GetEnvironmentVariable("FAKE_ROOT"), "copy-calls.txt"),
            String.Join(" ", args) + Environment.NewLine);
    }
}
'@
    $env:PATH = "$root;$oldPath"
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null) }
    $env:FAKE_ROOT = $root
    $env:FAKE_EXISTS = 'false'
    $env:PHOTO_UPLOAD_LOGS = Join-Path $root 'logs'

    $result = Run-Upload '-DryRun'
    Assert-True ($result.Code -eq 0) "Missing-container dry run failed: $($result.Err)"
    Assert-True ($result.Out -match 'WOULD be created \(private\)' -and $result.Out -match 'WOULD upload 2 file\(s\)') 'Dry run must report creation and exclude NEF/ZIP.'
    Assert-True ($result.Out -match 'valid 48 h') 'Default SAS lifetime must be 48 hours.'
    Assert-True ((Calls 'az-calls.txt') -notmatch 'container create|blob list') 'Dry run must not create or access a missing container.'

    $result = Run-Upload '-DryRun -CreateContainers no'
    Assert-True ($result.Code -eq 1 -and $result.Err -match 'not creating containers') 'Dry run with no must fail.'
    $result = Run-Upload '-RetryMode -CreateContainers yes'
    Assert-True ($result.Code -eq 1 -and $result.Err -match 'nothing to retry') 'Retry must not create a missing container.'
    $result = Run-Upload ''
    Assert-True ($result.Code -eq 1 -and $result.Err -match 'no terminal|cannot prompt') 'Unattended ask must fail safely.'

    Clear-Calls
    $env:FAKE_CREATE_FAIL = '1'
    $result = Run-Upload '-CreateContainers yes'
    Assert-True ($result.Code -eq 1 -and $result.Err -match 'creation denied') "Creation errors must be reported: $($result.Code) $($result.Err) $(Calls 'az-calls.txt')"
    Assert-True ((Calls 'az-calls.txt') -notmatch 'blob list') 'Creation failure must stop before access check.'
    $env:FAKE_CREATE_FAIL = '0'

    Clear-Calls
    $env:PHOTO_AZ_CREATE_CONTAINERS = 'yes'
    $result = Run-Upload '-CreateContainers no'
    Assert-True ($result.Code -eq 1 -and (Calls 'az-calls.txt') -notmatch 'container create') 'Explicit no must override the environment.'
    Clear-Calls
    $result = Run-Upload '-Transfer oauth'
    Assert-True ($result.Code -eq 1) "Expected simulated upload failures: $($result.Err)"
    $calls = Calls 'az-calls.txt'
    Assert-True ($calls -match 'storage container create.*--auth-mode login' -and $calls -match 'storage blob list') 'Creation must precede the blob access check.'
    $copyCalls = Calls 'copy-calls.txt'
    $passes = @($copyCalls -split "`r?`n" | Where-Object { $_ -match '^copy ' })
    Assert-True ($passes.Count -eq 2 -and @($passes | Where-Object { $_ -match '\(\?i\)\\\.\(nef\|zip\)\$' }).Count -eq 2) 'Both azcopy passes must exclude ignored extensions.'
    $report = Get-ChildItem -LiteralPath $env:PHOTO_UPLOAD_LOGS -Filter report.txt -Recurse | Select-Object -First 1
    Assert-True ($null -ne $report -and (Get-Content -Raw -LiteralPath $report.FullName) -match 'created\s+containers: photos') 'Report must list created containers.'

    $env:FAKE_EXISTS = 'true'
    $env:PHOTO_UPLOAD_IGNORE_EXTENSIONS = ' jpg '
    $result = Run-Upload '-DryRun'
    Assert-True ($result.Code -eq 0 -and $result.Out -match 'WOULD upload 3 file\(s\)' -and $result.Out -notmatch 'photo.jpg') 'Environment extension filter must be case insensitive and configurable.'
    $result = Run-Upload "-DryRun -IgnoreExtensions ''"
    Assert-True ($result.Code -eq 0 -and $result.Out -match 'WOULD upload 4 file\(s\)') 'Empty option must override the environment and include all files.'
    Assert-True ($result.Out -match '-> +photos/general/photo\.jpg' -and $result.Out -match 'photos/sub/image\.dng') 'The name of the source folder must be a folder in the container.'
    $result = Run-Upload "-DryRun -IgnoreExtensions '' -NoSourceFolder"
    Assert-True ($result.Code -eq 0 -and $result.Out -match '-> +general/photo\.jpg' -and $result.Out -notmatch 'photos/general') '-NoSourceFolder must upload the contents without the source folder name.'
    $result = Run-Upload "-DryRun -IgnoreExtensions 'nef,,zip'"
    Assert-True ($result.Code -eq 1 -and $result.Err -match 'comma-separated') 'Malformed extension lists must fail.'
    $retryRoot = Join-Path $root 'retry'
    $retry = Join-Path $retryRoot 'photos\general'
    $null = New-Item -ItemType Directory -Path $retry -Force
    Set-Content -LiteralPath (Join-Path $retry 'raw.NEF') -Value 'nef'
    Set-Content -LiteralPath (Join-Path $retry 'image.dng') -Value 'dng'
    $env:PHOTO_UPLOAD_IGNORE_EXTENSIONS = 'nef'
    $result = Run-Upload "-DryRun -RetryMode -RetryFolder '$($retryRoot.Replace("'", "''"))'"
    Assert-True ($result.Code -eq 0 -and $result.Out -match 'WOULD upload 1 file\(s\)' -and $result.Out -notmatch 'raw.NEF') 'Retry must use the same extension filter.'
    $env:FAKE_EXISTS = 'unknown'
    Clear-Calls
    $result = Run-Upload '-CreateContainers yes'
    Assert-True ($result.Code -eq 1 -and $result.Err -match 'unexpected response' -and (Calls 'az-calls.txt') -notmatch 'container create') 'Unexpected existence responses must not create containers.'
    Write-Output 'Upload integration tests passed.'
}
finally {
    $env:PATH = $oldPath
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
