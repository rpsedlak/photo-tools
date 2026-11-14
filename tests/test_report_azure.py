import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "cloud" / "report_azure.sh"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS file flags")
class ReportVisibilityTest(unittest.TestCase):
    def test_workbook_stays_visible_when_finder_hides_dot_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            az = root / "az"
            az.write_text("#!/bin/sh\nprintf '[]\\n'\n")
            az.chmod(0o755)
            (root / "sitecustomize.py").write_text(
                "import os, stat, tempfile\n"
                "original = tempfile.NamedTemporaryFile\n"
                "def named(*args, **kwargs):\n"
                "    result = original(*args, **kwargs)\n"
                "    if os.path.basename(result.name).startswith('.'):\n"
                "        os.chflags(result.name, os.stat(result.name).st_flags | stat.UF_HIDDEN)\n"
                "    return result\n"
                "tempfile.NamedTemporaryFile = named\n"
            )
            environment = os.environ.copy()
            environment.update({
                "PATH": str(root) + os.pathsep + environment["PATH"],
                "PYTHONPATH": str(root),
                "PHOTO_AZ_AUTH": "user",
            })
            report = root / "report.xlsx"
            result = subprocess.run(
                ["bash", str(SCRIPT), "-a", "account", "-d", report.name],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(report.stat().st_flags & stat.UF_HIDDEN)
            self.assertIn("Excel report written to {}".format(report), result.stdout)
            with zipfile.ZipFile(report) as workbook:
                self.assertIsNone(workbook.testzip())


if __name__ == "__main__":
    unittest.main()
