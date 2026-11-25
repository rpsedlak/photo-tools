import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
IMPORT_SCRIPT = ROOT / "workflow/phototools_import_photos.ps1"


@unittest.skipUnless(PWSH, "PowerShell is not installed")
class PowerShellPhotoImportTest(unittest.TestCase):
    def run_function(self, function_name, body, extra_env):
        script = rf"""
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:IMPORT_SCRIPT, [ref]$tokens, [ref]$errors)
$function = $ast.Find({{ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq '{function_name}' }}, $true)
. ([scriptblock]::Create($function.Extent.Text))
{body}
"""
        env = os.environ.copy()
        env.update({"IMPORT_SCRIPT": str(IMPORT_SCRIPT), **extra_env})
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-Command", script],
            capture_output=True, text=True, env=env,
        )

    def test_scan_enumeration_error_aborts(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(
                "Get-ScanFiles",
                "function Stop-Import { param([string]$Message) throw $Message }\n"
                "Get-ScanFiles (Join-Path $env:TEST_ROOT 'missing')",
                {"TEST_ROOT": tmp},
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read folder", result.stderr)

    def test_failed_filing_is_counted_and_keeps_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "incoming" / "photo.NEF"
            source.parent.mkdir()
            source.write_bytes(b"photo")
            result = self.run_function(
                "Move-ToFinal",
                r"""
function Test-PathExists { param([string]$Path) [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path) }
function Write-Err { param([string]$Text) }
$script:Failed = 0
$names = New-Object 'System.Collections.Generic.List[string]'
$filed = Move-ToFinal $env:SOURCE_PATH $env:DESTINATION_PATH $names
@($filed, $script:Failed, [IO.File]::Exists($env:SOURCE_PATH)) | ConvertTo-Json -Compress
""",
                {"SOURCE_PATH": str(source), "DESTINATION_PATH": str(root / "missing")},
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [False, 1, True])

    def test_filed_photo_rollback_restores_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            incoming = root / "incoming"
            filed = root / "filed"
            incoming.mkdir()
            filed.mkdir()
            destination = filed / "renamed.NEF"
            (filed / "renamed.NEF.xmp").write_text("qualified")
            (filed / "renamed.xmp").write_text("stem")
            destination.write_bytes(b"photo")
            source = incoming / "original.NEF"
            result = self.run_function(
                "Restore-FiledPhoto",
                r"""
function Write-Err { param([string]$Text) }
$restored = Restore-FiledPhoto $env:FILED_PATH $env:SOURCE_PATH
@($restored, [IO.File]::Exists($env:SOURCE_PATH),
  [IO.File]::Exists($env:SOURCE_PATH + '.xmp'),
  [IO.File]::Exists((Join-Path (Split-Path $env:SOURCE_PATH) 'original.xmp'))) | ConvertTo-Json -Compress
""",
                {"FILED_PATH": str(destination), "SOURCE_PATH": str(source)},
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [True, True, True, True])

    def test_dng_output_must_be_complete_and_valid(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "photo.dng"
            path.write_bytes(b"partial")
            result = self.run_function(
                "Test-DngOutput",
                r"""
function Invoke-ExifTool {
    param([string[]]$ToolArgs, [string[]]$CommonArgs)
    $script:ExifExit = 0
    if ($ToolArgs -contains '-validate') {
        $env:DNG_VALIDATION
        if ($ToolArgs -ccontains '-Validate') { $env:DNG_VALIDATION }
    }
    else { $env:DNG_VERSION }
}
$valid = Test-DngOutput $env:DNG_PATH
$env:DNG_VALIDATION = '2 Warnings (all minor)'
$minor = Test-DngOutput $env:DNG_PATH
$empty = Test-DngOutput $env:EMPTY_DNG_PATH
@($valid, $minor, $empty) | ConvertTo-Json -Compress
""",
                {
                    "DNG_PATH": str(path),
                    "EMPTY_DNG_PATH": str(Path(tmp) / "empty.dng"),
                    "DNG_VALIDATION": "OK",
                    "DNG_VERSION": "1.4.0.0",
                },
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [True, True, False])

    def test_dng_output_with_validation_errors_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "photo.dng"
            path.write_bytes(b"truncated")
            result = self.run_function(
                "Test-DngOutput",
                r"""
function Invoke-ExifTool {
    param([string[]]$ToolArgs, [string[]]$CommonArgs)
    $script:ExifExit = 0
    if ($ToolArgs -contains '-validate') { $env:DNG_VALIDATION }
    else { '1.4.0.0' }
}
$errorResult = Test-DngOutput $env:DNG_PATH
$env:DNG_VALIDATION = '1 Warning'
$warningResult = Test-DngOutput $env:DNG_PATH
@($errorResult, $warningResult) | ConvertTo-Json -Compress
""",
                {"DNG_PATH": str(path), "DNG_VALIDATION": "1 Error"},
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [False, False])


if __name__ == "__main__":
    unittest.main()
