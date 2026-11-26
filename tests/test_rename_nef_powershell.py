import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH and os.name != "nt", "PowerShell and a Unix-like test host are required")
class PowerShellNefRenameTest(unittest.TestCase):
    def test_sidecar_destination_is_reserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "photos"
            directory.mkdir()
            source = directory / "IMG.NEF"
            source.write_bytes(b"nef")
            (directory / "IMG.xmp").write_text("sidecar")
            (directory / "IMG.NEF.xmp").write_text("qualified sidecar")
            (directory / "20261017201845.xmp").write_text("existing sidecar")

            executable_dir = root / "bin"
            executable_dir.mkdir()
            exiftool = executable_dir / "exiftool"
            exiftool.write_text(
                "#!/bin/sh\n"
                "printf '%s\\t20261017201845\\t-\\n' \"$RENAME_TEST_SOURCE\"\n"
            )
            exiftool.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(executable_dir) + os.pathsep + env.get("PATH", "")
            env["RENAME_TEST_SOURCE"] = str(source)

            result = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-File",
                 str(ROOT / "workflow/phototools_rename_nef.ps1"), str(directory)],
                capture_output=True, text=True, env=env,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((directory / "20261017201845_1.NEF").is_file())
            self.assertTrue((directory / "20261017201845.xmp").is_file())
            self.assertTrue((directory / "20261017201845_1.xmp").is_file())
            self.assertTrue((directory / "20261017201845_1.NEF.xmp").is_file())
            self.assertFalse(source.exists())


if __name__ == "__main__":
    unittest.main()
