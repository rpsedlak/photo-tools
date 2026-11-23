import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell is not installed")
class PowerShellAzureUploadTest(unittest.TestCase):
    def test_normalizes_extended_unc_paths(self):
        script = r"""
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:UPLOAD_SCRIPT, [ref]$tokens, [ref]$errors)
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Normalize-AzCopyPath' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
@(
    (Normalize-AzCopyPath '\\?\UNC\nas\photos\trip\a.dng')
    (Normalize-AzCopyPath '\\?\unc\nas\photos\trip\a.dng')
    (Normalize-AzCopyPath '\\?\C:\photos\a.dng')
    (Normalize-AzCopyPath '\\nas\photos\a.dng')
) | ConvertTo-Json -Compress
"""
        env = os.environ.copy()
        env["UPLOAD_SCRIPT"] = str(ROOT / "cloud/phototools_upload_azure.ps1")
        result = subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-Command", script],
            capture_output=True, text=True, env=env,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            "//nas/photos/trip/a.dng",
            "//nas/photos/trip/a.dng",
            "C:/photos/a.dng",
            "//nas/photos/a.dng",
        ])


if __name__ == "__main__":
    unittest.main()
