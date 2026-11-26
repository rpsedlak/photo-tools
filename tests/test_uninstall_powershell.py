import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell is not installed")
class PowerShellUninstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        repo = self.root / "repo"
        (repo / "install").mkdir(parents=True)
        (repo / "cloud").mkdir()
        shutil.copy2(ROOT / "install/uninstall.ps1", repo / "install/uninstall.ps1")
        (repo / "cloud/phototools_new_tool.ps1").write_text("")
        self.script = repo / "install/uninstall.ps1"
        self.destination = self.root / "bin"
        self.destination.mkdir()
        for name in ("phototools_import_photos.ps1", "phototools_prune_nef.ps1", "phototools_new_tool.ps1"):
            (self.destination / name).write_text("")

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-File", str(self.script),
             "-Destination", str(self.destination), "-KeepPath", *args],
            capture_output=True, text=True, env=os.environ.copy(),
        )

    def test_dry_run_changes_nothing(self):
        result = self.run_script("-DryRun")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WOULD remove", result.stdout)
        self.assertIn("Dry run complete", result.stdout)
        self.assertEqual(len(list(self.destination.glob("*.ps1"))), 3)

    def test_removes_known_and_repository_scripts_only(self):
        (self.destination / "mine.ps1").write_text("")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([p.name for p in self.destination.iterdir()], ["mine.ps1"])
        self.assertIn("Removed 3 script(s)", result.stdout)

    def test_empty_folder_is_deleted(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.destination.exists())

    def test_nothing_to_remove(self):
        self.run_script()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No photo-tools scripts found to remove", result.stdout)


if __name__ == "__main__":
    unittest.main()
