import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class StreamDeckInstallationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        for directory in ("install", "tools", "cloud", "stream-deck", "other"):
            (self.repo / directory).mkdir(parents=True)
        for script in ("install.sh", "uninstall.sh"):
            shutil.copy2(ROOT / "install" / script, self.repo / "install" / script)
        (self.repo / "tools" / "phototools_prereqs.sh").write_text("#!/bin/bash\nexit 0\n")
        (self.repo / "cloud" / "phototools_upload_azure.sh").write_text("#!/bin/bash\n")
        for name in ("streamdeck_import_luring.command", "another.command"):
            (self.repo / "stream-deck" / name).write_text("#!/bin/zsh\n")
        (self.repo / "other" / "unrelated.command").write_text("#!/bin/zsh\n")
        self.dest = self.root / "bin"

    def run_script(self, script, *args):
        return subprocess.run(
            ["bash", str(self.repo / "install" / script), "-d", str(self.dest), *args],
            capture_output=True, text=True, check=True,
        )

    def test_install_and_uninstall_launchers(self):
        self.run_script("install.sh", "-n")
        self.assertFalse(self.dest.exists())

        self.run_script("install.sh")
        for name in ("streamdeck_import_luring.command", "another.command"):
            self.assertEqual((self.dest / name).stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.dest / "unrelated.command").exists())

        unrelated = self.dest / "unrelated.command"
        unrelated.write_text("keep")
        (self.dest / "streamdeck_import_general.command").write_text("old launcher")
        self.run_script("uninstall.sh", "-n")
        self.assertTrue((self.dest / "streamdeck_import_luring.command").exists())

        self.run_script("uninstall.sh")
        for name in ("streamdeck_import_luring.command", "another.command",
                     "streamdeck_import_general.command", "phototools_upload_azure.sh"):
            self.assertFalse((self.dest / name).exists())
        self.assertEqual(unrelated.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
