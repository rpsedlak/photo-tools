import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
SCRIPT = ROOT / "workflow/phototools_rename_dng.ps1"

# A fake exiftool that prints "<path>\t<date>" for every DNG in RENAME_TEST_FILES
# (lines of "<path>\t<date>"), like exiftool -p '$Directory/$FileName\t$DateTimeOriginal'.
FAKE_EXIFTOOL = "#!/bin/sh\ncat \"$RENAME_TEST_FILES\"\n"


@unittest.skipUnless(PWSH and os.name != "nt", "PowerShell and a Unix-like test host are required")
class PowerShellDngRenameTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.directory = self.root / "dng"
        self.directory.mkdir()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        exiftool = bin_dir / "exiftool"
        exiftool.write_text(FAKE_EXIFTOOL)
        exiftool.chmod(0o755)
        self.listing = self.root / "listing.txt"
        self.env = os.environ.copy()
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env.get("PATH", "")
        self.env["RENAME_TEST_FILES"] = str(self.listing)

    def tearDown(self):
        self.tmp.cleanup()

    def make(self, name, date, content=b"dng"):
        path = self.directory / name
        path.write_bytes(content)
        with self.listing.open("a") as handle:
            handle.write("{}\t{}\n".format(path, date))
        return path

    def run_script(self, *args):
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-File", str(SCRIPT), *args],
            capture_output=True, text=True, env=self.env, stdin=subprocess.DEVNULL,
        )

    def test_renames_with_serials_and_sidecars(self):
        (self.directory / "20261017-detroit-riverwalk-00007.dng").write_bytes(b"old")
        self.make("A.dng", "20261017")
        (self.directory / "A.xmp").write_text("sidecar")
        (self.directory / "A.dng.xmp").write_text("qualified sidecar")
        self.make("B.dng", "20261018")
        self.make("20261017-detroit-riverwalk-00007.dng", "20261017", b"old")

        result = self.run_script("-EventName", "Detroit Riverwalk", str(self.directory))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.directory / "20261017-detroit-riverwalk-00007.dng").is_file())
        self.assertTrue((self.directory / "20261017-detroit-riverwalk-00008.dng").is_file())
        self.assertTrue((self.directory / "20261017-detroit-riverwalk-00008.xmp").is_file())
        self.assertTrue((self.directory / "20261017-detroit-riverwalk-00008.dng.xmp").is_file())
        self.assertTrue((self.directory / "20261018-detroit-riverwalk-00001.dng").is_file())
        self.assertFalse((self.directory / "A.dng").exists())
        self.assertIn("Renamed: 2   Skipped: 1   Failed: 0", result.stdout)

    def test_dry_run_changes_nothing(self):
        self.make("A.dng", "20261017")
        result = self.run_script("-DryRun", "-EventName", "Event", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WOULD", result.stdout)
        self.assertIn("20261017-event-00001.dng", result.stdout)
        self.assertTrue((self.directory / "A.dng").is_file())

    def test_missing_date_uses_modification_time(self):
        path = self.make("A.dng", "-")
        stamp = 1700000000
        os.utime(path, (stamp, stamp))
        result = self.run_script("-EventName", "Event", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        names = [p.name for p in self.directory.glob("*.dng")]
        self.assertEqual(len(names), 1)
        self.assertRegex(names[0], r"^2023111[34]-event-00001\.dng$")

    def test_requires_event_name(self):
        result = self.run_script(str(self.directory))
        self.assertEqual(result.returncode, 1)
        self.assertIn("event name is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
