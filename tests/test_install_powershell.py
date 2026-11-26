import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell is not installed")
class PowerShellInstallationTest(unittest.TestCase):
    def test_installs_prefixed_scripts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            for directory in ("install", "tools", "cloud", "workflow"):
                (root / directory).mkdir(parents=True)
            shutil.copy2(ROOT / "install/install.ps1", root / "install/install.ps1")
            for relative in (
                "cloud/phototools_upload_azure.ps1",
                "tools/phototools_update.ps1",
                "workflow/phototools_import_photos.ps1",
                "workflow/phototools_rename_nef.ps1",
            ):
                shutil.copy2(ROOT / relative, root / relative)
            (root / "tools/phototools_prereqs.ps1").write_text("param([switch]$CheckOnly)\nexit 0\n")
            destination = Path(tmp) / "bin"
            result = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-File", str(root / "install/install.ps1"),
                 "-Destination", str(destination), "-NoPath"],
                capture_output=True, text=True, env=os.environ.copy(),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                {p.name for p in destination.glob("*.ps1")},
                {"phototools_upload_azure.ps1", "phototools_update.ps1",
                 "phototools_import_photos.ps1", "phototools_rename_nef.ps1",
                 "phototools_prereqs.ps1"},
            )


if __name__ == "__main__":
    unittest.main()
